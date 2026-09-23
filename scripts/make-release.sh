#!/bin/bash
# ==============================================================================
# 生成 release 包（需求 §54）
#
# 用法: scripts/make-release.sh <bin_dir> <build_version>
# 产物: releases/r1c-gateway-<ver>/
#         -sysupgrade.bin / -initramfs-kernel.bin
#         sha256sums / manifest / config.buildinfo / build.log
# ==============================================================================
set -u

BIN_DIR="${1:?缺少 bin_dir}"
VERSION="${2:?缺少 version}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$BASE_DIR/openwrt"
PROFILE="r1c-gateway"
OUT="$BASE_DIR/releases/${PROFILE}-${VERSION}"

mkdir -p "$OUT"

# ------------------------------------------------------------------------------
# 内核版本探测
# 不能读 include/kernel.mk —— 那里是 "LINUX_VERSION?=" 占位符，取出来会是
# 字面量 "<LINUX_VERSION>"。实际可用的来源按可靠性排序：
#   1. ipk 文件名            kmod-tun_6.6.156-1_mipsel_24kc.ipk
#   2. build_dir 目录名      build_dir/linux-ramips_mt7620/linux-6.6.156
#   3. KERNEL_PATCHVER + include/kernel-<v> 的 LINUX_VERSION-<v> 后缀 → 6.6 + .156
#   4. 仅 KERNEL_PATCHVER（退化，只有 6.6）
#
# 实测 note：OpenWrt 24.10 起 kmod 包改由独立 packages repo 分发，
# target 的 bin 目录下常常不再有 packages/*.ipk，因此 1 经常落空；
# 3 是离线最可靠的完整版本来源（例：LINUX_VERSION-6.6 = .156）。
# ------------------------------------------------------------------------------
detect_kernel() {
    local v="" pv="" suffix="" esc=""
    # 1) 从 ipk 提取：<name>_<ver>-<rel>_<arch>.ipk
    v=$(find "$BIN_DIR" -maxdepth 3 -name '*.ipk' -printf '%f\n' 2>/dev/null \
        | head -1 | sed -nE 's/^.*_([0-9]+\.[0-9]+(\.[0-9]+)?)-[0-9]+_.*$/\1/p')
    [ -n "$v" ] && { echo "$v"; return; }
    # 2) 从已解压的内核源码目录名提取
    v=$(ls -d "$SRC_DIR"/build_dir/linux-*ramips*/linux-* 2>/dev/null \
        | head -1 | sed -nE 's#.*/linux-([0-9]+\.[0-9]+(\.[0-9]+)?)$#\1#p')
    [ -n "$v" ] && { echo "$v"; return; }
    # 3) KERNEL_PATCHVER + include/kernel-<pv> 的版本后缀
    pv=$(sed -nE 's/^KERNEL_PATCHVER:=([0-9.]+).*/\1/p' \
        "$SRC_DIR/target/linux/ramips/Makefile" 2>/dev/null | head -1)
    if [ -n "$pv" ]; then
        esc=${pv//./\\.}   # 6.6 -> 6\.6，避免 sed 正则里 . 通配
        suffix=$(sed -nE "s/^LINUX_VERSION-${esc}[[:space:]]*=[[:space:]]*([0-9.]+).*/\1/p" \
            "$SRC_DIR/include/kernel-${pv}" 2>/dev/null | head -1)
        if [ -n "$suffix" ]; then
            echo "${pv}${suffix}"    # 6.6 + .156 = 6.6.156
            return
        fi
        echo "$pv"                   # 4) 退化
        return
    fi
    echo "unknown"
}

mkdir -p "$OUT"

# 镜像
for f in "$BIN_DIR"/*miwifi-mini*.bin; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
        *sysupgrade*)        cp "$f" "$OUT/${PROFILE}-${VERSION}-sysupgrade.bin" ;;
        *initramfs-kernel*)  cp "$f" "$OUT/${PROFILE}-${VERSION}-initramfs-kernel.bin" ;;
        *)                   cp "$f" "$OUT/$(basename "$f")" ;;
    esac
done

# SHA256
( cd "$OUT" && sha256sum *.bin > sha256sums )

# config.buildinfo
[ -f "$SRC_DIR/.config" ] && cp "$SRC_DIR/.config" "$OUT/config.buildinfo"

# manifest
{
    echo "profile:        $PROFILE"
    echo "version:        $VERSION"
    echo "build_date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "device:         xiaomi_miwifi-mini (Xiaomi MiWiFi Mini / R1C)"
    echo "target:         ramips/mt7620"
    echo "arch:           mipsel_24kc"
    echo "source:         openwrt/openwrt (openwrt-24.10)"
    # 注意：文件名是 source.commit（曾误写为 openwrt.commit，导致 manifest 恒为 unknown）
    echo "source_commit:  $(cat "$BASE_DIR/source.commit" 2>/dev/null || echo unknown)"
    echo "kernel:         $(detect_kernel)"
    echo ""
    echo "[images]"
    ( cd "$OUT" && ls -l *.bin 2>/dev/null | awk '{print "  "$9"  "$5" bytes"}')
    echo ""
    echo "[firmware_size_limit]"
    echo "  IMAGE_SIZE:   15872 KiB"
    echo ""
    echo "[enabled_vpn]"
    echo "  wireguard:    PRIMARY  (installed)"
    echo "  zerotier:     OPTIONAL (installed, service disabled by default)"
    echo "  tailscale:    EXPERIMENTAL - NOT INCLUDED (installed size 24.9 MiB > flash budget)"
    echo "  cloudflared:  NOT SUPPORTED ON R1C (25.9 MiB + no ICMP over WARP routing)"
} > "$OUT/manifest"

# build.log
# 完整编译日志可达数十 MB，直接塞进 Release 既不理性也无必要。
# 归档策略：错误/警告全量保留，其余只留尾部；超 20000 行则截断。
summarize_build_log() {
    local src="$1" dst="$2"
    local total
    total=$(wc -l < "$src" 2>/dev/null || echo 0)
    {
        echo "# Build log (excerpt) — total ${total} lines"
        echo "# Full log is retained in the Actions run output."
        echo ""
        echo "===== ERRORS / FATAL ====="
        grep -nE "Error [0-9]+|make.*\*\*\*|Makefile:[0-9]+:.*Error|FATAL|No space left" "$src" \
            | head -100 || true
        echo ""
        echo "===== WARNINGS (first 100) ====="
        grep -nE "WARNING|warning:" "$src" | head -100 || true
        echo ""
        echo "===== TAIL (last 3000 lines of ${total}) ====="
        tail -n 3000 "$src"
    } > "$dst"
}

if [ -f "$BASE_DIR/build.log" ]; then
    summarize_build_log "$BASE_DIR/build.log" "$OUT/build.log"
    SIZE=$(du -h "$OUT/build.log" | cut -f1)
    echo "  -> build.log: $SIZE (摘录)"
else
    echo "build.log not captured (run: make ... 2>&1 | tee build.log)" > "$OUT/build.log"
fi

echo "✅ Release 已生成: $OUT"
ls -l "$OUT"
