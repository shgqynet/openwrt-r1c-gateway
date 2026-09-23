#!/bin/bash
# ==============================================================================
# 10-r1c-gateway.sh — 注入 R1C 网关的软件与默认配置
# 在 feeds install 之后执行（当前工作目录为 openwrt 源码根）
# ==============================================================================

echo "[r1c] 集成自研包 package/r1c-gateway"
for pkg in r1c-gateway; do
    if [ -d "$REPO_SRC/package/$pkg" ]; then
        rm -rf "package/$pkg"
        cp -r "$REPO_SRC/package/$pkg" "package/$pkg"
        # 包的 install 依赖自身目录下的 files/，由工程根 files/ 同步过来
        rm -rf "package/$pkg/files"
        cp -r "$REPO_SRC/files" "package/$pkg/files"
        echo "  -> copied package/$pkg (+files)"
    else
        echo "  ⚠️  未找到 $REPO_SRC/package/$pkg"
    fi
done

echo "[r1c] 注入 files/ 到 rootfs overlay"
if [ -d "$REPO_SRC/files" ]; then
    mkdir -p files
    cp -r "$REPO_SRC/files/." files/
    echo "  -> files overlay 已合并"
fi

echo "[r1c] 设置默认主机名与 Site ID 占位（真实 Site ID 由 /etc/r1c/site.conf 提供）"
sed -i 's/^option hostname.*/option hostname\t\t'"'"'r1c-site-000'"'"'/' \
    package/base-files/files/etc/config/system 2>/dev/null || true

echo "[r1c] 确保时区与日志默认（RAM log，禁止高频写 Flash）"
if [ -f package/base-files/files/etc/config/system ]; then
    grep -q "option zonename" package/base-files/files/etc/config/system || \
        sed -i '/config system/a\	option zonename		'"'"'Asia/Shanghai'"'"'\n	option timezone		'"'"'CST-8'"'"'' \
        package/base-files/files/etc/config/system
fi

echo "✅ [r1c] diy 注入完成"
