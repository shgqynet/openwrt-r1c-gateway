#!/bin/sh
# 出厂预置 root 密码 —— 让 VPN_HTTP_ACCESS="allow" 在开箱状态下就真的生效。
#
# 为什么必须有这一步：
#   r1c-apply 在放行 VPN 侧管理后台（TCP 80/443）前，会先查 /etc/shadow 里 root
#   有没有密码哈希；空密码 / 锁定状态一律拒绝放行。理由很实在 —— 刚刷出来的设备
#   root 无密码，此时放行等于任何握到 WG 密钥的隧道对端都能匿名进后台改配置。
#   而刚刷完的固件 root 恰恰没有密码，所以「出厂 allow」不配出厂密码就是空转。
#
# ⚠️ 只在 root **当前没有密码** 时写入：
#   - 现场已经 passwd 过的设备不会被覆盖（sysupgrade 后本脚本会随新固件再跑一次，
#     但检测到已有哈希就直接跳过，绝不改现场密码）
#   - 仓库里只存 sha256crypt 哈希，不存明文
#   - 出厂密码是公开的默认值，现场部署后**必须** passwd 改掉
DEFAULT_ROOT_HASH='$5$r1cfactory$3Fj9IPD5JD/Ynq3DtvRS2plJ7N7UTTdPe1S8kWyhnr2'

_pw=$(grep '^root:' /etc/shadow 2>/dev/null | cut -d: -f2)
case "$_pw" in
    ''|'!'*|'*')
        # 用 | 作分隔符：哈希里含 / 和 $，用 / 会把替换表达式切断
        sed -i "s|^root:[^:]*:|root:${DEFAULT_ROOT_HASH}:|" /etc/shadow
        echo "[r1c] 出厂 root 密码已设置；部署到现场后请用 passwd 修改"
        ;;
    *)
        echo "[r1c] root 已有密码，保持不动"
        ;;
esac

exit 0
