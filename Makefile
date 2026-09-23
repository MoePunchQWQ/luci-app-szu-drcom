include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-szu-drcom
PKG_VERSION:=1.0.0
PKG_RELEASE:=2
PKG_MAINTAINER:=szu-drcom contributors
PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_ARCH:=all

LUCI_TITLE:=SZU Dr.COM ePortal client with LuCI panel
LUCI_DESCRIPTION:=Graphical LuCI client for the Shenzhen University Dr.COM \
	ePortal campus network. Supports one-click login/logout, an auto \
	reconnect daemon, live status and logs.
LUCI_DEPENDS:=+curl +uci +luci-base +luci-lua-runtime +libuci-lua

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=LuCI
  TITLE:=SZU Dr.COM ePortal client (LuCI)
  URL:=https://github.com/szu-drcom/luci-app-szu-drcom
  DEPENDS:=+curl +uci +luci-base +luci-lua-runtime +libuci-lua
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  $(LUCI_DESCRIPTION)
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/drcom_szu
endef

define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/drcom_szu 2>/dev/null
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/drcom_szu ]; then
	/etc/init.d/drcom_szu stop >/dev/null 2>&1 || true
	/etc/init.d/drcom_szu disable >/dev/null 2>&1 || true
fi
exit 0
endef

# No sources to build: every file is installed straight from ./files.
# Mirrors the base-files pattern for source-less packages.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/szu-drcom $(1)/usr/bin/szu-drcom
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/drcom_szu $(1)/etc/config/drcom_szu
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/drcom_szu $(1)/etc/init.d/drcom_szu
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/szu_drcom.lua \
		$(1)/usr/lib/lua/luci/controller/szu_drcom.lua
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/szu_drcom
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/szu_drcom/status.htm \
		$(1)/usr/lib/lua/luci/view/szu_drcom/status.htm
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-szu-drcom.json
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
