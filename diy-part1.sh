#!/bin/bash
# ==============================================================================
# diy-part1.sh — 在 feeds update 之前执行
# 用途：修改 feeds.conf.default
#
# 与参考仓库的差异（重要）：
#   参考仓库在此处 sed 解注释 helloworld 并加入 OpenClash 源 —— 本项目全部剔除。
#   工业网关不引入任何代理/穿透类第三方源（需求 §46/§72）。
# ==============================================================================
set -e

# 1. 确保 helloworld（SSR-Plus 源）保持注释状态
sed -i 's|^\(src-git helloworld\)|#\1|' feeds.conf.default

# 2. 移除可能存在的 OpenClash / 第三方穿透源
sed -i '/openclash/d' feeds.conf.default
sed -i '/OpenClash/d' feeds.conf.default

# 3. 校验：除了官方 feeds，不应有其他源
echo "--- feeds.conf.default ---"
cat feeds.conf.default
echo "--------------------------"
