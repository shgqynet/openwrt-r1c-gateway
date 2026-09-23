#!/bin/sh
# ==============================================================================
# 手机热点 WAN 的 STA 接口模板（需求 §12）
#
# 为什么用 uci-defaults 而不是直接提供 /etc/config/wireless：
#   无线 radio 的 path / band / channel 由系统首次启动时按实际硬件探测生成，
#   手工写死放 files/etc/config/wireless 一旦 path 写错，整个无线会失效，
#   而本设备可依赖的带外恢复手段有限（仅 TTL 串口），不值得冒这个风险。
#   这里改为在探测完成后用 uci 追加一个 iface，规避该风险。
#
# 认证方式：WPA2-PSK（psk2）
#   依据：2026-09-23 用户确认「现场使用普通 WiFi 安全协议够了」，不启用 WPA3。
#   若将来需要 WPA3(SAE)，encryption 改为 sae-mixed 并换用 wpad-openssl，
#   同时需按 §43/§44 重新核算 Flash 预算。
#
# 默认状态：disabled=1（禁用）
#   依据：需求 §29 默认安全策略「Remote Access OFF」。
#   现场部署时按实际热点填写 SSID / KEY 后手动启用，不预置任何真实凭据。
# ==============================================================================

[ -f /etc/config/wireless ] || {
    logger -t r1c-wireless "未找到 /etc/config/wireless，跳过 STA 模板注入"
    exit 0
}

# radio0 = SoC rt2800 (2.4G)。手机热点绝大多数开在 2.4G，作为 STA 首选它。
if ! uci -q get wireless.radio0 >/dev/null; then
    logger -t r1c-wireless "未找到 radio0，跳过 STA 模板注入"
    exit 0
fi

# 已存在则不重复注入（脚本可能因 sysupgrade 保留配置而再次执行）
if uci -q get wireless.r1c_wwan >/dev/null; then
    exit 0
fi

uci -q batch <<'EOF'
set wireless.r1c_wwan=wifi-iface
set wireless.r1c_wwan.device='radio0'
set wireless.r1c_wwan.network='wwan'
set wireless.r1c_wwan.mode='sta'
set wireless.r1c_wwan.ssid='CHANGEME-PHONE-HOTSPOT'
set wireless.r1c_wwan.encryption='psk2'
set wireless.r1c_wwan.key='CHANGEME-PASSWORD'
set wireless.r1c_wwan.disabled='1'
commit wireless
EOF

logger -t r1c-wireless "已注入 STA 模板 wireless.r1c_wwan（默认禁用，需填 SSID/KEY 后启用）"

exit 0
