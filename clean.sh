#!/bin/bash
# ==============================================================================
# 清理构建产物 / 缓存
#   ./clean.sh          仅清理产物与临时文件
#   ./clean.sh all      同时清理 openwrt 源码树（会删除所有编译缓存，慎用）
# ==============================================================================
set -e
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

echo "[clean] 清理构建日志与 release 临时文件"
rm -f build.log
rm -rf .workbuddy/tmp

if [ "${1:-}" = "all" ]; then
    echo "[clean] 清理 openwrt 源码树（含全部编译缓存）"
    read -r -p "确认删除 ./openwrt ? [y/N] " ans
    [ "$ans" = "y" ] && rm -rf openwrt && echo "已删除"
else
    echo "[clean] 保留 openwrt/（编译缓存已保留）"
    echo "        如需全清: ./clean.sh all"
fi

echo "✅ 清理完成"
