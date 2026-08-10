include $(TOPDIR)/rules.mk

PKG_NAME:=rustive
PKG_VERSION:=0.1.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Mohy <fahimohy@gmail.com>

RUSTIVE_IPK:=rustive_$(PKG_VERSION)_mipsel_24kc.ipk
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/rustive
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=Rustive service for HLK MT7628
  DEPENDS:=@TARGET_ramips_mt76x8 +libgcc
endef

define Package/rustive/description
  Prebuilt Rust application and supporting scripts for the HLK MT7628 device.
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	$(INSTALL_DIR) $(PKG_BUILD_DIR)
	gzip -dc $(CURDIR)/files/$(RUSTIVE_IPK) | tar -xf - -C $(PKG_BUILD_DIR)
	tar -xzf $(PKG_BUILD_DIR)/data.tar.gz -C $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/rustive/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/rustive $(1)/usr/bin/rustive
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/capture.sh $(1)/usr/bin/capture.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/usr/bin/white_list.sh $(1)/usr/bin/white_list.sh
	$(INSTALL_DIR) $(1)/etc/rustive
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/rustive/dhcp_script.sh $(1)/etc/rustive/dhcp_script.sh
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/etc/init.d/rustive $(1)/etc/init.d/rustive
endef

$(eval $(call BuildPackage,rustive))
