#!/bin/sh
# ==============================================================================
# 5G 兜底应急 AP（现场不用网线也能连上网关改配置）
#
# 为什么必须有它：
#   上行是手机热点 STA（2.4G）。现场一换手机/改热点密码 → STA 连不上 → 隧道断
#   → Ubuntu 服务器管理页连不上网关 → 改不了 WiFi → **死锁**。
#   本地应急管理页 /cgi-bin/r1c 本来能破这个死锁，但如果网关不发射任何无线，
#   现场就必须带电脑 + 网线才能开那个页面 —— 真到现场往往没有。
#   所以：5G 射频常开一个 AP，手机/笔记本直接连它开管理页。
#
# 为什么放 5G（radio0）而不是 2.4G：
#   2.4G（radio1）要留给 STA 连手机热点，两块射频独立，AP 与 STA 互不影响；
#   且现场热点的干扰几乎全在 2.4G，应急 AP 放 5G 更干净。
#
# 为什么默认启用（与 STA 模板的 disabled=1 不同）：
#   它就是"最后一根稻草"，出厂禁用等于没有。风险由 WPA2 密码承担。
#   若现场要求零无线暴露：uci set wireless.r1c_ap.disabled=1; uci commit wireless; wifi reload
#
# AP 桥接 lan 的代价（有意为之）：
#   客户端会拿到 LAN/PLC 网段的地址，与 PLC 处于同一广播域。
#   应急场景短时连接可接受；为降低撞车概率，DHCP 池从默认的 .100-.249
#   收窄到 **.240-.249**（PLC 几乎不会用这么高的地址）。
# ==============================================================================

AP_SSID='99999999'
AP_KEY='99999999'

[ -f /etc/config/wireless ] || {
    logger -t r1c-ap "未找到 /etc/config/wireless，跳过应急 AP 注入"
    exit 0
}

# 已存在则不重复注入（sysupgrade 保留配置时会再次执行）
uci -q get wireless.r1c_ap >/dev/null && exit 0

# ------------------------------------------------------------------------------
# 找 5G 射频：优先认 band/hwmode，认不出来就退化为"STA 没占用的那块"
# ------------------------------------------------------------------------------
RADIOS=$(uci show wireless 2>/dev/null \
         | sed -n 's/^wireless\.\(radio[0-9]*\)=wifi-device$/\1/p')

RADIO5=""
for r in $RADIOS; do
    b=$(uci -q get "wireless.$r.band" 2>/dev/null)
    h=$(uci -q get "wireless.$r.hwmode" 2>/dev/null)
    case "$b$h" in
        *5g*|*11a*) RADIO5="$r"; break ;;
    esac
done

if [ -z "$RADIO5" ]; then
    STA_R=$(uci -q get wireless.r1c_wwan.device 2>/dev/null)
    for r in $RADIOS; do
        [ "$r" != "$STA_R" ] && { RADIO5="$r"; break; }
    done
fi

[ -n "$RADIO5" ] || {
    logger -t r1c-ap "未找到可用的 5G 射频，跳过应急 AP 注入"
    exit 0
}

uci -q batch <<EOF
set wireless.${RADIO5}.disabled='0'
set wireless.r1c_ap=wifi-iface
set wireless.r1c_ap.device='${RADIO5}'
set wireless.r1c_ap.network='lan'
set wireless.r1c_ap.mode='ap'
set wireless.r1c_ap.ssid='${AP_SSID}'
set wireless.r1c_ap.encryption='psk2'
set wireless.r1c_ap.key='${AP_KEY}'
set wireless.r1c_ap.disabled='0'
commit wireless
EOF

# DHCP 池收窄到 .240-.249：应急 AP 只服务 1-2 个临时连接，
# 同时避开 PLC 常用的低中段地址（默认池 .100-.249 会盖住像 .181 这种 PLC 地址）。
uci -q batch <<'EOF'
set dhcp.lan.start='240'
set dhcp.lan.limit='10'
commit dhcp
EOF

logger -t r1c-ap "已注入 5G 应急 AP wireless.r1c_ap (${AP_SSID} on ${RADIO5}, 桥接 lan)，DHCP 池收窄为 .240-.249"

# 手动执行时用 --apply 让配置立即生效；首次启动时由系统统一拉起无线，不需要。
[ "$1" = "--apply" ] && wifi reload

exit 0
