# ==============================================================================
# r1c-gateway — R1C 工业远程网关核心包
#
# 提供：状态检测 / VPN 状态 / WAN 检测 / PLC 检测 / LED / 自动恢复 / 日志
#       命令行工具 r1c-status / r1c-diagnose / r1c-test-plc
#
# 阶段：Phase 1 骨架（业务逻辑在 Phase 2-9 逐步填充）
# ==============================================================================
include $(TOPDIR)/rules.mk

PKG_NAME:=r1c-gateway
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/r1c-gateway
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=R1C Industrial Gateway
  TITLE:=R1C Industrial Remote Gateway service and CLI
  DEPENDS:=+kmod-wireguard +wireguard-tools +ip-full +iputils-ping
  PKGARCH:=all
endef

define Package/r1c-gateway/description
  Industrial remote gateway service for Xiaomi MiWiFi Mini (R1C).
  Provides WAN/VPN/PLC health checks, LED status, auto recovery and CLI tools.
endef

define Build/Prepare
	true
endef

define Build/Compile
	true
endef

# ⚠️ 新增文件必须在此登记，否则不会被打进固件。
#    曾漏登记 r1c-apply，导致构建成功但设备上看不到该工具（静默缺失，不报错）。
#    files/ 目录由 diy-part2.d/10-r1c-gateway.sh 同步进包目录 ./files。
define Package/r1c-gateway/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/r1c-gateway $(1)/etc/init.d/r1c-gateway
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/r1c-status $(1)/usr/bin/r1c-status
	$(INSTALL_BIN) ./files/usr/bin/r1c-diagnose $(1)/usr/bin/r1c-diagnose
	$(INSTALL_BIN) ./files/usr/bin/r1c-test-plc $(1)/usr/bin/r1c-test-plc
	$(INSTALL_BIN) ./files/usr/bin/r1c-apply $(1)/usr/bin/r1c-apply
	$(INSTALL_BIN) ./files/usr/bin/r1c-wg-watchdog $(1)/usr/bin/r1c-wg-watchdog
	$(INSTALL_DIR) $(1)/etc/r1c
	$(INSTALL_CONF) ./files/etc/r1c/site.conf $(1)/etc/r1c/site.conf
	# sysupgrade 保留 /etc/r1c/ —— 没有这条，升级会把站点配置和 WG 私钥一起抹掉。
	#
	# ⚠️ 这个坑是 2026-10-07 准备刷机时实测发现的：/etc/sysupgrade.conf 里只有
	#    /etc/config/ 等系统项，**不包含 /etc/r1c/**，而 WG 私钥存在
	#    /etc/r1c/wg-private.key。升完级：LAN/无线配置因 /etc/config/ 保留而活着，
	#    但 site.conf 没了 → PLC 网段、设备清单、端点全丢，表现是"刷完隧道还在、
	#    PLC 不通"，极易误判成网络问题。
	#    OpenWrt 的机制：保留项 = /etc/sysupgrade.conf + /lib/upgrade/keep.d/* 里的行。
	#    放 keep.d 而不追加 sysupgrade.conf，是因为前者随包安装、不吃用户改动。
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/lib/upgrade/keep.d/r1c-gateway \
		$(1)/lib/upgrade/keep.d/r1c-gateway
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-r1c-wireless-sta.sh \
		$(1)/etc/uci-defaults/90-r1c-wireless-sta.sh
	$(INSTALL_BIN) ./files/etc/uci-defaults/91-r1c-luci-lang.sh \
		$(1)/etc/uci-defaults/91-r1c-luci-lang.sh
	# 5G 兜底应急 AP：现场换热点改了密码、隧道断掉时的最后一根稻草，
	# 不用网线也能连上网关开本地管理页（详见脚本头注释）
	$(INSTALL_BIN) ./files/etc/uci-defaults/92-r1c-emergency-ap.sh \
		$(1)/etc/uci-defaults/92-r1c-emergency-ap.sh
	# 出厂 root 密码：没有它，出厂的 VPN_HTTP_ACCESS="allow" 会被 r1c-apply 的
	# 「root 无密码则拒绝放行」校验挡掉，刷完照样打不开后台（详见脚本头注释）。
	$(INSTALL_BIN) ./files/etc/uci-defaults/93-r1c-root-password.sh \
		$(1)/etc/uci-defaults/93-r1c-root-password.sh
	# 本地应急管理页（http://<lan-ip>/cgi-bin/r1c）
	#
	# ⚠️ 不要改成 /usr/lib/lua/luci/ 下的 LuCI 页面：
	#    24.10 的 luci-base 是 26.x 纯 JS 架构，菜单由 /usr/share/luci/menu.d/*.json
	#    定义，不再扫描 Lua controller；而且本固件**没有 lua 解释器**，
	#    menu.json 的 template action 渲染时直接报 "No Lua runtime installed"。
	#    本页是纯 busybox ash 的 CGI，零新增依赖 —— 隧道断了照样能开。
	$(INSTALL_DIR) $(1)/www/cgi-bin
	$(INSTALL_BIN) ./files/www/cgi-bin/r1c $(1)/www/cgi-bin/r1c
	# LuCI 菜单入口：把上面的 CGI 页嵌进后台（不是重写成 LuCI 表单，理由同上）。
	# 缺了 menu.d 这一项，页面能打开但后台目录里看不到入口（2026-10-07 踩）。
	# USB 4G / 手机共享网络热插拔接管：模块插上后由 usb-modeswitch 切成网卡，
	# 再由这个 hotplug 脚本绑到 wan4g 并拉起（详见脚本头注释）。
	# 少了它，4G 只能靠"插着模块再跑一次 r1c-apply"才能用。
	$(INSTALL_DIR) $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) ./files/etc/hotplug.d/usb/95-r1c-usb-wan.sh \
		$(1)/etc/hotplug.d/usb/95-r1c-usb-wan.sh
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-r1c.json \
		$(1)/usr/share/luci/menu.d/luci-app-r1c.json
	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/r1c
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/r1c/gateway.js \
		$(1)/www/luci-static/resources/view/r1c/gateway.js
endef

define Package/r1c-gateway/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
  /etc/init.d/r1c-gateway enable
}
exit 0
endef

$(eval $(call BuildPackage,r1c-gateway))
