#!/bin/bash
# ==============================================================================
# 固件大小检查（需求 §44）
#
# 用法: scripts/check-size.sh <image.bin> [IMAGE_SIZE_KiB]
# 退出码: 0=OK / 0=WARN / 1=BUILD FAILED
#
# 依据: mt7620.mk 中 xiaomi_miwifi-mini 的 IMAGE_SIZE := 15872k
#       官方 24.10.5 基础镜像实测 6528 KiB -> 剩余预算约 9.1 MiB
# ==============================================================================
set -u

IMG="${1:?用法: check-size.sh <image.bin>}"
LIMIT_K="${2:-15872}"
WARN_K=$((12 * 1024))     # 12288 KiB
FAIL_K=$((15 * 1024))     # 15360 KiB

[ -f "$IMG" ] || { echo "❌ 文件不存在: $IMG"; exit 1; }

SIZE=$(stat -c%s "$IMG")
SIZE_K=$((SIZE / 1024))

echo "镜像        : $(basename "$IMG")"
echo "实际大小    : ${SIZE} B (${SIZE_K} KiB)"
echo "IMAGE_SIZE  : ${LIMIT_K} KiB"
echo "剩余预算    : $((LIMIT_K - SIZE_K)) KiB"

if [ "$SIZE_K" -gt "$LIMIT_K" ]; then
    echo "❌ BUILD FAILED: 超过 IMAGE_SIZE (${LIMIT_K} KiB)，刷入会失败"
    exit 1
elif [ "$SIZE_K" -gt "$FAIL_K" ]; then
    echo "❌ BUILD FAILED: 超过 15 MiB 安全上限，overlay 无空间"
    exit 1
elif [ "$SIZE_K" -gt "$WARN_K" ]; then
    echo "⚠️  WARN: 超过 12 MiB，overlay 空间不足，禁止继续加包"
    exit 0
fi

echo "✅ 体积检查通过"
exit 0
