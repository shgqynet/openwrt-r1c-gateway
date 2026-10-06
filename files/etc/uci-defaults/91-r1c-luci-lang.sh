#!/bin/sh
# ==============================================================================
# 91-r1c-luci-lang.sh — LuCI 默认界面语言设为简体中文
#
# 语言包由 configs/r1c-gateway.config 里的 luci-i18n-*-zh-cn 提供。
# 这里只负责"默认选中文"：LuCI 的 lang 默认可能是 auto（跟随浏览器），
# 现场工程师的浏览器环境不可控，固定为 zh_cn 更稳。
#
# 只在用户尚未手动指定时写入，不覆盖现场已做的选择。
# ==============================================================================

[ -f /etc/config/luci ] || exit 0

CUR=$(uci -q get luci.main.lang 2>/dev/null)

# 未设置、或仍是 auto 时才改为 zh_cn
if [ -z "$CUR" ] || [ "$CUR" = "auto" ]; then
    uci -q set luci.main.lang='zh_cn'
    uci -q commit luci
    logger -t r1c "LuCI 默认语言已设为 zh_cn"
fi

exit 0
