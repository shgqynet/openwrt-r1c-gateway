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
    echo "source_commit:  $(cat "$BASE_DIR/openwrt.commit" 2>/dev/null || echo unknown)"
    echo "kernel:         $(grep -m1 'LINUX_VERSION' "$SRC_DIR/include/kernel.mk" 2>/dev/null || echo n/a)"
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
if [ -f "$BASE_DIR/build.log" ]; then
    cp "$BASE_DIR/build.log" "$OUT/build.log"
else
    echo "build.log not captured (run: make ... 2>&1 | tee build.log)" > "$OUT/build.log"
fi

echo "✅ Release 已生成: $OUT"
ls -l "$OUT"
