#!/bin/bash
# ==============================================================================
# R1C Gateway —— 通过 SSH 在设备上执行验收与固化刷机
#
# 运行位置：工程师电脑（本机），不是路由器上。
# 前提：设备已跑起 OpenWrt（通常是 initramfs RAM 版），且与本机二层可达。
#
# ⚠️  红线（需求 §64 / §68，脚本内外都不可违反）
#     - 只使用 sysupgrade，它只写 firmware 分区
#     - 永不 mtd write 到 factory / Bdata / Config / u-boot / u-boot-env
#     - 永不修改 U-Boot / breed / 分区表
#     - flash 子命令默认 dry-run，必须显式加 --apply 才真正写入
#
# 子命令
#   probe    连通性 + 只读采集（分区表、板型、MAC、运行模式）
#   verify   Phase 2 验收清单（需求 §55），全部只读
#   flash    上传镜像并 sysupgrade 固化（默认 dry-run）
#
# 用法
#   ./scripts/flash-over-ssh.sh probe
#   ./scripts/flash-over-ssh.sh verify
#   ./scripts/flash-over-ssh.sh flash --image ./out/sysupgrade.bin
#   ./scripts/flash-over-ssh.sh flash --image ./out/sysupgrade.bin --apply
#
# 常用选项
#   --host <ip>      默认 192.168.1.1
#   --port <n>       默认 22
#   --image <path>   仅 flash 需要
#   --apply          flash 真正执行（不加则只打印将要做什么）
#   --no-wait        sysupgrade 后不等设备上线
# ==============================================================================
set -uo pipefail

HOST="192.168.1.1"
PORT="22"
IMAGE=""
APPLY="0"
WAIT="1"
CMD=""

# flash 分区硬上限（见 HARDWARE.md：firmware = 15872 KiB）
MAX_BYTES=$((15872 * 1024))

# dropbear 不支持新版 SFTP 协议，scp 必须用 -O 走传统 scp 协议。
# 注意端口选项大小写不同：ssh 是 -p，scp 是 -P（scp 的 -p 是"保留时间戳"，切勿混用）
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o ConnectTimeout=6 -o LogLevel=ERROR -p ${PORT}"
SCP_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
-o ConnectTimeout=6 -o LogLevel=ERROR -P ${PORT}"

die()  { echo "❌ $*"; exit 1; }
info() { echo "ℹ️  $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
hr()   { echo "----------------------------------------------"; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        probe|verify|flash) CMD="$1"; shift ;;
        --host)  HOST="$2";  shift 2 ;;
        --port)  PORT="$2";  shift 2 ;;
        --image) IMAGE="$2"; shift 2 ;;
        --apply) APPLY="1";  shift ;;
        --no-wait) WAIT="0"; shift ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（用 --help 看用法）" ;;
    esac
done

[ -n "$CMD" ] || usage

# 远端执行（连不上直接失败，便于脚本使用者立刻知道通道断了）
r() { ssh $SSH_OPTS "root@${HOST}" "$@"; }

wait_online() {
    local deadline=$((SECONDS + 180))
    info "等待 ${HOST} 上线（最多 180s）..."
    while [ $SECONDS -lt $deadline ]; do
        if ssh $SSH_OPTS -o BatchMode=yes "root@${HOST}" "true" >/dev/null 2>&1; then
            ok "${HOST} 已上线"
            return 0
        fi
        sleep 3
    done
    warn "180s 内未上线 —— 不要慌，先按 FIRST-BOOT.md 第 6 节排查"
    return 1
}

# ------------------------------------------------------------------------------
echo "=============================================="
echo " R1C Gateway over SSH   目标: root@${HOST}:${PORT}"
echo " 子命令: ${CMD}   时间: $(date '+%F %T')"
echo "=============================================="

# 连通性
if ! ssh $SSH_OPTS -o BatchMode=yes "root@${HOST}" "true" >/dev/null 2>&1; then
    die "无法 SSH 到 ${HOST}。检查：网线在 LAN 口？本机 IP 是否 192.168.1.x/24？设备起来了没？"
fi
ok "SSH 通道已建立"
hr

case "$CMD" in

# ==============================================================================
probe)
    echo "--- 系统 ---"
    r "cat /etc/openwrt_release 2>/dev/null | grep -E 'DISTRIB_(ID|RELEASE|TARGET|ARCH)'"
    r "uname -a"
    echo
    echo "--- 板型（sysupgrade 用它校验，必须匹配）---"
    r "cat /tmp/sysinfo/board_name 2>/dev/null; cat /tmp/sysinfo/model 2>/dev/null"
    echo
    echo "--- 运行模式：initramfs(RAM) 还是固化系统 ---"
    r "grep -q 'root=/dev/ram\|initramfs' /proc/cmdline && echo 'RAM / initramfs（未固化，断电回到 breed）' || echo 'Flash / 固化系统'"
    r "mount | grep -E ' / .*(tmpfs|ramfs|overlay)' | head -3"
    echo
    echo "--- 分区表（关键：factory 必须 read-only）---"
    r "cat /proc/mtd"
    echo
    echo "--- Flash 容量 ---"
    r "dmesg | grep -iE 'mtd.*partition|flash.*found' | tail -8"
    echo
    echo "--- MAC（factory 偏移 0x28，全 00/11:22:33 属异常）---"
    r "FW=\$(grep '\"factory\"' /proc/mtd | cut -d: -f1)
[ -n \"\$FW\" ] && hexdump -C /dev/\$FW -s 0x28 -n 6 || echo '未找到 factory 分区'"
    r "ifconfig -a | grep -iE 'eth0|wlan|HWaddr' | head -6"
    echo
    echo "--- 自研工具是否都在（应为 4 个）---"
    r "which r1c-apply r1c-status r1c-diagnose r1c-test-plc"
    echo
    echo "--- 内存（决定能否在 /tmp 放下镜像）---"
    r "free | head -2; df -h /tmp | tail -1"
    ;;

# ==============================================================================
verify)
    r "cat /proc/mtd"
    echo
    echo "--- 1. 工具清单 ---"
    r "for t in r1c-apply r1c-status r1c-diagnose r1c-test-plc; do command -v \$t >/dev/null && echo \"OK   \$t\" || echo \"MISS \$t\"; done"
    echo
    echo "--- 2. 占位配置必须被拒绝（期望 exit 1）---"
    r "r1c-apply --check; echo \"exit=\$?\""
    echo
    echo "--- 3. r1c-status / diagnose ---"
    r "r1c-status 2>&1 | head -30"
    r "r1c-diagnose 2>&1 | head -40"
    echo
    echo "--- 4. 交换机（应为 swconfig 非 DSA）---"
    r "swconfig list 2>&1; swconfig dev switch0 show 2>/dev/null | head -20"
    echo
    echo "--- 5. 无线（2.4G rt2800 + 5G mt76x2）---"
    r "iw list 2>/dev/null | grep -E 'Band|phy'| head -6; uci show wireless 2>/dev/null | grep -c wifi-iface"
    echo
    echo "--- 6. LED ---"
    r "ls /sys/class/leds/ 2>/dev/null"
    echo
    echo "--- 7. USB ---"
    r "lsusb 2>/dev/null || echo '（未插设备或无 lsusb）'"
    echo
    echo "--- 8. MAC 真实性 ---"
    r "FW=\$(grep '\"factory\"' /proc/mtd | cut -d: -f1); [ -n \"\$FW\" ] && hexdump -C /dev/\$FW -s 0x28 -n 6"
    echo
    ok "验收采集完成 —— 逐项对照 docs/FIRST-BOOT.md 第 3 节判读"
    ;;

# ==============================================================================
flash)
    [ -n "$IMAGE" ]  || die "flash 需要 --image <本地 sysupgrade.bin 路径>"
    [ -f "$IMAGE" ]  || die "镜像不存在: $IMAGE"

    case "$IMAGE" in
        *sysupgrade*.bin) : ;;
        *) die "只允许 sysupgrade 镜像固化：$IMAGE
   initramfs-kernel.bin 用于首次 RAM 验证（在 breed 界面刷），不能用来固化" ;;
    esac

    SIZE=$(stat -c%s "$IMAGE")
    echo "镜像: $IMAGE"
    echo "体积: ${SIZE} bytes ($((SIZE/1024)) KiB) / 上限 ${MAX_BYTES} bytes ($((MAX_BYTES/1024)) KiB)"
    [ "$SIZE" -le "$MAX_BYTES" ] || die "镜像超过 firmware 分区容量，禁止刷入"

    LOCAL_SHA=$(sha256sum "$IMAGE" | cut -d' ' -f1)
    echo "本地 sha256: $LOCAL_SHA"
    hr

    # 远端预检：板型 + 剩余内存 + /tmp 空间
    echo "--- 远端预检 ---"
    BOARD=$(r "cat /tmp/sysinfo/board_name 2>/dev/null")
    echo "板型: ${BOARD:-未知}"
    case "$BOARD" in
        *miwifi-mini*) ok "板型匹配 xiaomi_miwifi-mini" ;;
        *) warn "板型非 xiaomi_miwifi-mini —— sysupgrade 很可能拒绝，先人工确认再继续" ;;
    esac
    r "free | head -2"
    hr

    if [ "$APPLY" != "1" ]; then
        echo "🔎 DRY-RUN —— 以下动作尚未执行，加 --apply 才真正写入："
        echo "   1) scp -O $IMAGE -> root@${HOST}:/tmp/$(basename "$IMAGE")"
        echo "   2) 远端 sha256 校验，必须与 ${LOCAL_SHA:0:16}... 一致"
        echo "   3) 远端执行 sysupgrade -n /tmp/$(basename "$IMAGE")   ← 只写 firmware 分区"
        echo "   4) 等待设备重启上线并回读版本"
        echo
        echo "   永不触碰：factory / Bdata / Config / u-boot / u-boot-env"
        exit 0
    fi

    REMOTE="/tmp/$(basename "$IMAGE")"

    echo "--- 上传 ---"
    if scp -O $SCP_OPTS "$IMAGE" "root@${HOST}:${REMOTE}" 2>/dev/null; then
        ok "scp 上传完成"
    else
        warn "scp 失败，改用 ssh 管道上传"
        ssh $SSH_OPTS "root@${HOST}" "cat > ${REMOTE}" < "$IMAGE" \
            || die "上传失败"
        ok "管道上传完成"
    fi

    echo "--- 校验 ---"
    REMOTE_SHA=$(r "sha256sum ${REMOTE} | cut -d' ' -f1")
    echo "远端 sha256: $REMOTE_SHA"
    [ "$REMOTE_SHA" = "$LOCAL_SHA" ] || die "校验不一致！已中止，远端文件未被动用"
    ok "校验一致"
    hr

    echo "--- 执行 sysupgrade（只写 firmware 分区）---"
    echo "    命令: sysupgrade -n ${REMOTE}"
    # 连接会在重启时断开，退出码非 0 属正常，不据此判失败
    r "sync; sysupgrade -n ${REMOTE}" 2>&1 | tail -5
    echo "(连接断开属预期行为)"
    hr

    if [ "$WAIT" = "1" ]; then
        wait_online || exit 1
        echo "--- 固化后回读 ---"
        r "cat /etc/openwrt_release | grep -E 'DISTRIB_RELEASE|DISTRIB_TARGET'"
        r "cat /tmp/sysinfo/board_name"
        r "cat /proc/mtd"
        r "for t in r1c-apply r1c-status r1c-diagnose r1c-test-plc; do command -v \$t >/dev/null && echo \"OK   \$t\" || echo \"MISS \$t\"; done"
        ok "固化完成"
    else
        info "已跳过等待，请手动确认设备重新上线"
    fi
    ;;

esac

echo
echo "=============================================="
echo " 本脚本只使用 sysupgrade，未执行任何 mtd write"
echo "=============================================="
