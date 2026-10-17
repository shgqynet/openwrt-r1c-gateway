#!/bin/sh
# r1c-lan-guard —— br-lan 开机自愈
#
# 【症状】开机后 LAN 桥偶尔拿不到 IP：/sys/class/net 里根本**没有 eth0.1**，
#   br-lan 存在但 state DOWN，`ifstatus lan` 报 DEVICE_CLAIM_FAILED。
#   此时 R1C 自己的隧道/WiFi 上行都正常（Hub 上看它"在线"），但：
#     · ping 它的 PLC_LOCAL_IP（如 172.21.12.254）100% 丢
#     · 22 端口 Connection refused
#     · Hub「远程配置网关」读不到 site.conf、「远程监控」拿不到状态
#   —— 因为这两处走的都是 **lan_ip**，不是隧道 IP。
#
# 【处理】分级修复，成功即退出：
#   1~2 次：补建 eth0.1 → 挂进 br-lan → ifup lan
#   第 3 次：直接 /etc/init.d/network restart（实测：有的机器光 ifup 不够，
#            netifd 卡在 DEVICE_CLAIM_FAILED，只有整网重启才肯重新认领）
#   之后：再回到 ifup lan 兜底
#
# 放在 /etc/r1c/ 下是为了 sysupgrade 后能保留（keep.d 已登记该目录）。

TAG=r1c-lan-guard

# 单实例锁：新固件里由 /etc/init.d/r1c-lan-guard 拉起，而旧机器上
# /etc/rc.local 里的钩子 sysupgrade 后会保留 —— 两边同时跑也没害处，
# 但没必要，加把锁保证只有一个实例。
LOCK=/tmp/.r1c-lan-guard.lock
mkdir "$LOCK" 2>/dev/null || { logger -t "$TAG" "已有实例在运行，退出"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

sleep 20

i=0
while [ $i -lt 8 ]; do
    if ip -4 addr show br-lan 2>/dev/null | grep -q 'inet '; then
        logger -t "$TAG" "br-lan 已就绪"
        exit 0
    fi

    i=$((i + 1))
    logger -t "$TAG" "br-lan 无 IPv4 地址，第 $i 次修复"

    # 交换机里的 VLAN 1 是好的，缺的只是内核 VLAN 设备
    ip link show eth0.1 >/dev/null 2>&1 \
        || ip link add link eth0 name eth0.1 type vlan id 1 2>/dev/null
    ip link set eth0.1 up 2>/dev/null

    ip link show br-lan >/dev/null 2>&1 \
        || ip link add name br-lan type bridge 2>/dev/null
    ip link set eth0.1 master br-lan 2>/dev/null
    ip link set br-lan up 2>/dev/null

    if [ "$i" = "3" ] || [ "$i" = "6" ]; then
        logger -t "$TAG" "升级处理：重启整个网络（会短暂断网后自愈）"
        /etc/init.d/network restart >/dev/null 2>&1
        sleep 25
    else
        ifup lan >/dev/null 2>&1
        sleep 10
    fi
done

logger -t "$TAG" "br-lan 仍未拿到地址，放弃（共尝试 8 次）"
exit 1
