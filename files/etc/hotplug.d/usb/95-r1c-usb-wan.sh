#!/bin/sh
# USB 4G 模块 / 手机 USB 共享网络 —— 插上后自动接管为上行
#
# 为什么需要这个脚本：
#   4G 模块插上后并不会立刻变成网卡。华为 E3131 之类默认停在 U 盘模式
#   （12d1:1f01），要先由 usb-modeswitch 切成网卡模式（→ 12d1:14db），
#   cdc_ether 才会注册出 eth1。这个过程要几秒，USB add 事件触发时网卡**还不存在**。
#   所以这里不能直接读网卡，必须延后探测。
#
# 触发链：
#   USB add → 本脚本后台起探测 → sleep 8 → 按驱动名找网卡
#           → 更新 network.wan4g / wantether 的 device → ifup → mwan3 自动纳管
#
# 前提：接口段由 r1c-apply 预先建好（即使当时没插模块也会建，auto=0 待命）。
#   本脚本**只补 device 并拉起，不凭空新建接口** —— 否则在还没跑过 r1c-apply
#   的设备上会冒出一个配置不完整的接口，反而干扰排障。
#
# 判断依据同样是"有没有网络接口"而不是 lsusb（理由见 r1c-apply 的 detect_usb_net）。

LOCK=/tmp/r1c-usb-wan.lock

# 按驱动名探测 USB 网卡。命中即输出设备名（eth1 / usb0 ...）
probe_dev() {
    for _d in /sys/class/net/*; do
        [ -e "$_d/device/uevent" ] || continue
        _drv=$(sed -n 's/^DRIVER=//p' "$_d/device/uevent" 2>/dev/null)
        for _w in "$@"; do
            if [ "$_drv" = "$_w" ]; then echo "${_d##*/}"; return 0; fi
        done
    done
    return 1
}

# 把探测到的网卡绑到既有接口并拉起。接口段不存在则什么都不做。
attach_iface() { # attach_iface <uci接口名> <设备名>
    _iface=$1
    _dev=$2
    [ "$(uci -q get "network.$_iface" 2>/dev/null)" = "interface" ] || return 0
    if [ "$(uci -q get "network.$_iface.device" 2>/dev/null)" = "$_dev" ] \
       && [ "$(uci -q get "network.$_iface.auto" 2>/dev/null)" = "1" ]; then
        return 0    # 已经是这个设备且已启用，无需重复动作
    fi
    uci set "network.$_iface.device=$_dev"
    uci set "network.$_iface.auto=1"
    uci commit network
    logger -t r1c-usb-wan "检测到网卡 $_dev，启用上行接口 $_iface"
    ifup "$_iface" >/dev/null 2>&1
}

if [ "$1" = "--probe" ]; then
    # 等 usb-modeswitch 完成模式切换（实测 E3131 约 3~5 秒，留一倍余量）
    sleep 8

    _d4g=$(probe_dev cdc_ncm huawei_cdc_ncm cdc_ether)
    [ -n "$_d4g" ] && attach_iface wan4g "$_d4g"

    _dt=$(probe_dev rndis_host)
    [ -n "$_dt" ] && attach_iface wantether "$_dt"

    rm -rf "$LOCK"
    exit 0
fi

# hotplug 入口：只处理插入事件；用目录锁防重入（USB 枚举会连发多个事件）
[ "$ACTION" = "add" ] || exit 0
mkdir "$LOCK" 2>/dev/null || exit 0

setsid "$0" --probe >/dev/null 2>&1 &
exit 0
