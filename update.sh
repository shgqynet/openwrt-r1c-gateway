#!/bin/bash
# ==============================================================================
# R1C Industrial Remote Gateway — 增量构建脚本
#
# 适用：源码更新 / 修改了 config 加减包 / 修改了 files 或 package
# 保留编译缓存，通常几分钟出镜像。
#
# 注意（与参考仓库一致）：
#   - git clean 时必须排除我们手动复制进来的本地包目录，否则会被删掉触发重编
#   - 工业固件锁定 commit，默认【不】跟随 lede master 更新
# ==============================================================================
set -e
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

[ -d "$BASE_DIR/lede" ] || { echo "❌ 未找到 lede/，请先执行 ./build.sh"; exit 1; }

cd lede

echo "[1/5] 撤销上一次 diy 造成的源码改动（保留缓存）"
git checkout .
# 排除本地注入的包，防止被清理后触发全量重编
git clean -df -e package/r1c-gateway

echo "[2/5] 源码版本（锁定模式）"
if [ -f "$BASE_DIR/lede.commit" ]; then
    LOCKED=$(tr -d ' \t\r\n' < "$BASE_DIR/lede.commit")
    echo "  锁定 commit: $LOCKED"
    git fetch --all
    git checkout -f "$LOCKED"
else
    echo "  ⚠️  未锁定，使用当前 HEAD: $(git rev-parse HEAD)"
fi

echo "[3/5] 更新 feeds（保留缓存）"
./scripts/feeds update -a
./scripts/feeds install -a
[ -f "$BASE_DIR/diy-part2.sh" ] && bash "$BASE_DIR/diy-part2.sh"

echo "[4/5] 重载配置"
cp "$BASE_DIR/configs/r1c-gateway.config" .config
make defconfig
BUILD_VERSION="${BUILD_VERSION:-$(date +"%Y.%m.%d-%H%M")}"
sed -i '/^CONFIG_VERSION_NUMBER=/d' .config
echo "CONFIG_VERSION_NUMBER=\"${BUILD_VERSION}\"" >> .config

echo "[5/5] 增量编译"
make -j$(( $(nproc) + 1 )) V=s 2>&1 | tee "$BASE_DIR/build.log"

echo "✅ 增量构建完成（版本 $BUILD_VERSION）"
