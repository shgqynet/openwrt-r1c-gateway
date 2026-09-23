#!/bin/bash
# ==============================================================================
# R1C Industrial Remote Gateway - 全量构建脚本
#
# 源码树 : openwrt/openwrt openwrt-24.10 (kernel 6.6)
#          —— 由 Lean's lede 迁移，原因见 docs/BUILD.md §2（lede 5.10 的
#             crypto.mk 存在CONFIG_CRYPTO_LIB_CHACHA_GENERIC 符号不匹配，
#             导致 kmod-crypto-lib-chacha20 / WireGuard 无法构建，CI 已实证）
# 设备   : ramips/mt7620 -> xiaomi_miwifi-mini (Xiaomi MiWiFi Mini / R1C)
# 架构   : mipsel_24kc    Flash: 16MiB (firmware 分区 15872 KiB)
#
# 步骤：1 依赖 2 源码 3 feeds 4 config 5 patch 6 编译 7 体积检查
#       8 sha256 9 manifest 10 release
#
# 安全红线：本脚本绝不执行 mtd write / sysupgrade / U-Boot 修改 / 分区变更
# ==============================================================================
set -e

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

SRC_DIR="$BASE_DIR/openwrt"
SRC_BRANCH="openwrt-24.10"
COMMIT_FILE="$BASE_DIR/source.commit"
PROFILE="r1c-gateway"
export BUILD_VERSION="${BUILD_VERSION:-$(date +"%Y.%m.%d-%H%M")}"

# Flash 预算 (byte) —— 来自 mt7620.mk IMAGE_SIZE := 15872k
IMAGE_SIZE_LIMIT=$((15872 * 1024))
SIZE_FAIL=$((15 * 1024 * 1024))
SIZE_WARN=$((12 * 1024 * 1024))

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------- 1. 依赖检查
log "[1/10] 检查构建环境"
[ "$EUID" -eq 0 ] && { echo "❌ 禁止使用 root 编译"; exit 1; }
[[ "$BASE_DIR" == *" "* ]] && { echo "❌ 路径不能包含空格: $BASE_DIR"; exit 1; }
FREE_GB=$(($(df -k . | tail -n1 | awk '{print $4}') / 1024 / 1024))
[ "$FREE_GB" -lt 30 ] && { echo "❌ 磁盘剩余 ${FREE_GB}GB < 30GB"; exit 1; }
echo "✅ 环境检查通过（可用 ${FREE_GB}GB）"

if [ -f scripts/deps-ubuntu.sh ]; then
    bash scripts/deps-ubuntu.sh
fi

# ---------------------------------------------------------------- 2. 获取源码
log "[2/10] 获取 OpenWrt 官方源码 ($SRC_BRANCH)"
if [ ! -d "$SRC_DIR" ]; then
    git clone --depth 1 https://github.com/openwrt/openwrt.git -b "$SRC_BRANCH" "$SRC_DIR"
else
    ( cd "$SRC_DIR" && git fetch --depth 1 origin "$SRC_BRANCH" && git reset --hard FETCH_HEAD )
fi
# 锁定 commit：工业固件必须可复现，禁止追分支滚动更新
if [ -f "$COMMIT_FILE" ]; then
    LOCKED=$(tr -d ' \t\r\n' < "$COMMIT_FILE")
    [ -n "$LOCKED" ] && ( cd "$SRC_DIR" && git fetch --depth 1 origin "$LOCKED" && git checkout -f "$LOCKED" ) \
        && echo "✅ 已锁定源码 commit: $LOCKED"
else
    ( cd "$SRC_DIR" && git rev-parse HEAD > "$COMMIT_FILE" )
    echo "⚠️  未找到 source.commit，已记录当前 HEAD: $(cat "$COMMIT_FILE")"
fi

cd "$SRC_DIR"

# ---------------------------------------------------------------- 3. Feeds
log "[3/10] 更新并安装 Feeds"
[ -f "$BASE_DIR/diy-part1.sh" ] && bash "$BASE_DIR/diy-part1.sh"
./scripts/feeds update -a
./scripts/feeds install -a
[ -f "$BASE_DIR/diy-part2.sh" ] && bash "$BASE_DIR/diy-part2.sh"

# ---------------------------------------------------------------- 4. 加载配置
log "[4/10] 加载 R1C 配置"
if [ ! -f "$BASE_DIR/configs/$PROFILE.config" ]; then
    echo "❌ 缺少 configs/$PROFILE.config"; exit 1
fi
cp "$BASE_DIR/configs/$PROFILE.config" .config
make defconfig
# defconfig 会覆盖版本号，必须在之后注入
sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
echo "CONFIG_VERSION_NUMBER=\"${BUILD_VERSION}\"" >> .config
echo "✅ 版本已注入: $BUILD_VERSION"

# ---------------------------------------------------------------- 5. 补丁
log "[5/10] 应用补丁"
if [ -d "$BASE_DIR/patches" ]; then
    for p in $(ls "$BASE_DIR/patches"/*.patch 2>/dev/null | sort); do
        echo "  -> apply $(basename "$p")"
        git apply --check "$p" 2>/dev/null && git apply "$p" || echo "  ⚠️  跳过（已应用或不适用）: $(basename "$p")"
    done
fi

# ---------------------------------------------------------------- 6. 编译
log "[6/10] 下载依赖源码包"
set +e
for i in 1 2 3; do
    make download -j8 V=s && break
    echo "⚠️  下载失败，第 $i 次重试..."
    [ "$i" -eq 3 ] && { echo "❌ 下载连续失败 3 次，请检查网络"; exit 1; }
    sleep 3
done
set -e

log "[6/10] 开始编译（耗时较长）"
CORES=$(( $(nproc) + 1 ))
set +e
make -j"$CORES" V=s
RES=$?
set -e
if [ "$RES" -ne 0 ]; then
    echo "⚠️  多核编译失败，切换单核复现错误..."
    make -j1 V=s || { echo "❌ 编译失败"; exit 1; }
fi

# ---------------------------------------------------------------- 7. 体积检查
log "[7/10] 固件大小检查（需求 §44）"
BIN_DIR=$(find bin/targets -type d -name "*mt7620*" | head -1)
[ -z "$BIN_DIR" ] && { echo "❌ 未找到产物目录"; exit 1; }
SYSUP=$(ls "$BIN_DIR"/*miwifi-mini*squashfs-sysupgrade.bin 2>/dev/null | head -1)
[ -z "$SYSUP" ] && { echo "❌ 未找到 sysupgrade 镜像"; exit 1; }

SIZE=$(stat -c%s "$SYSUP")
echo "  镜像: $(basename "$SYSUP")"
echo "  大小: $SIZE bytes ($((SIZE/1024)) KiB) / 上限 15872 KiB"
if [ "$SIZE" -gt "$IMAGE_SIZE_LIMIT" ]; then
    echo "❌ BUILD FAILED: 超过 IMAGE_SIZE (15872 KiB)"; exit 1
elif [ "$SIZE" -gt "$SIZE_FAIL" ]; then
    echo "❌ BUILD FAILED: 超过 15 MiB 安全上限"; exit 1
elif [ "$SIZE" -gt "$SIZE_WARN" ]; then
    echo "⚠️  WARN: 超过 12 MiB，overlay 空间不足，禁止继续加包"
else
    echo "✅ 体积检查通过"
fi

# ---------------------------------------------------------------- 8-10. 发布
log "[8-10/10] 生成 sha256 / manifest / release 包"
bash "$BASE_DIR/scripts/make-release.sh" "$BIN_DIR" "$BUILD_VERSION"

log "🎉 构建完成: releases/${PROFILE}-${BUILD_VERSION}/"
