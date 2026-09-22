include $(TOPDIR)/rules.mk

PKG_NAME:=mm-utils
PKG_VERSION:=1.0.0
PKG_RELEASE:=2

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

define Package/mm-utils
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Local modem and asynchronous SMS API
  PKGARCH:=all
  DEPENDS:=+modemmanager +lua +libubox-lua +libubus-lua +luci-lib-jsonc +uhttpd-mod-lua
endef

define Package/mm-utils/description
  Provides the local modem API, a procd-managed asynchronous SMS queue,
  and a ModemManager/mmcli SMS sender.
endef

define Package/mm-utils/conffiles
/etc/config/sms-api
endef

define Build/Compile
endef

define Package/mm-utils/install
	$(INSTALL_DIR) $(1)/www/api
	$(INSTALL_DATA) ./files/www/api/handler.lua $(1)/www/api/handler.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua
	$(INSTALL_DATA) ./files/usr/lib/lua/sms_api.lua $(1)/usr/lib/lua/sms_api.lua

	$(INSTALL_DIR) $(1)/usr/libexec $(1)/usr/sbin
	$(INSTALL_BIN) ./files/usr/libexec/sms-api-send $(1)/usr/libexec/sms-api-send
	$(INSTALL_BIN) ./files/usr/sbin/sms-api-worker $(1)/usr/sbin/sms-api-worker

	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/init.d $(1)/etc/uci-defaults
	$(INSTALL_CONF) ./files/etc/config/sms-api $(1)/etc/config/sms-api
	$(INSTALL_BIN) ./files/etc/init.d/sms-api $(1)/etc/init.d/sms-api
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-mm-utils-uhttpd \
		$(1)/etc/uci-defaults/90-mm-utils-uhttpd
endef

$(eval $(call BuildPackage,mm-utils))
