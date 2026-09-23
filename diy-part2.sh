#!/bin/bash
# ==============================================================================
# diy-part2.sh — 在 feeds install 之后、make defconfig 之前执行
# 用途：按顺序 source diy-part2.d/*.sh
# ==============================================================================

export REPO_SRC="$GITHUB_WORKSPACE"
if [ -z "$REPO_SRC" ]; then
    REPO_SRC="$(cd "$(dirname "$0")" && pwd)"
fi

script_dir="$REPO_SRC/diy-part2.d"

if [ ! -d "$script_dir" ]; then
    echo "⚠️  未找到 $script_dir，跳过"
    exit 0
fi

for script in $(ls "$script_dir"/*.sh | sort); do
    [ -f "$script" ] || continue
    echo "---------------------------------------------"
    echo "-> $(basename "$script")"
    echo "---------------------------------------------"
    # shellcheck disable=SC1090
    source "$script"
done

echo "✅ 所有 diy-part2 脚本执行完毕"
