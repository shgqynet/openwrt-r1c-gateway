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
	$(INSTALL_DIR) $(1)/etc/r1c
	$(INSTALL_CONF) ./files/etc/r1c/site.conf $(1)/etc/r1c/site.conf
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-r1c-wireless-sta.sh \
		$(1)/etc/uci-defaults/90-r1c-wireless-sta.sh
endef

define Package/r1c-gateway/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
  /etc/init.d/r1c-gateway enable
}
exit 0
endef

$(eval $(call BuildPackage,r1c-gateway))
