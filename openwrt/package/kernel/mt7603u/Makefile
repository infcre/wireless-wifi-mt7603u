#
# MediaTek MT7603U USB vendor driver for OpenWrt
# (360 WiFi 3 / "360随身WiFi 3", USB 0e8d:760c)
#
# Two kernel packages are produced from one source tree, because one module
# implements exactly one operating mode:
#
#   kmod-mt7603u-ap    hostapd drives it as an access point   (WIFI_MODE=AP)
#   kmod-mt7603u-sta   wpa_supplicant drives it as a station  (WIFI_MODE=STA)
#
# They cannot be installed together: both register the USB driver name "mt_drv"
# and claim the same USB ID, so whichever probes first wins.  The packages
# therefore CONFLICT with each other; switch modes by installing the other one.
#
# A third, non-kernel package carries the pieces both modes need at runtime:
#
#   mt7603u-files      firmware blobs + /etc/Wireless/*.dat driver config
#
# ---------------------------------------------------------------------------
# Why the build looks the way it does (read this before "fixing" it)
# ---------------------------------------------------------------------------
#
# OpenWrt does NOT use the kernel's own cfg80211.  kmod-cfg80211 is built from
# the backports tree (6.12.6 for the 24.10 series), so on a 6.6.93 kernel the
# wireless API the driver must talk to is 6.12.  Two consequences:
#
#  1. The driver has to be compiled against the mac80211/ header tree that
#     OpenWrt installs into staging, not against the in-kernel 6.6 headers.
#     Those -I paths must go through NOSTDINC_FLAGS: kbuild puts
#     $(NOSTDINC_FLAGS) *before* $(LINUXINCLUDE), while ccflags-y comes after,
#     so a path passed via ccflags-y loses against the kernel's own include/.
#     Getting this wrong does not fail the build -- it silently links against
#     6.6 struct layouts and corrupts memory at runtime.
#
#  2. rt_6x_compat.h needs to know the cfg80211 API generation separately from
#     the kernel version (RTMP_CFG80211_API_VER=612 here).  Likewise
#     RTMP_CFG80211_WEXT=0: OpenWrt's cfg80211 is built without WEXT, which
#     changes struct wiphy / struct wireless_dev layouts and removes the
#     wireless_send_event / iwe_stream_add_* symbols entirely.
#
# The driver also needs a handful of symbols that only cfg80211 exports.  Since
# kmod-cfg80211 is not part of the kernel tree, modpost cannot see them; we feed
# it symvers/cfg80211.symvers (generated from OpenWrt 24.10.2's own
# kmod-cfg80211, see README) so that a missing/renamed symbol is a hard build
# error instead of a runtime "unknown symbol" surprise.
#
# -Wno-error is required: this is 2014 vendor code and OpenWrt enables
# CONFIG_WERROR.  Real errors still abort the build.
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=mt7603u
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_LICENSE_FILES:=GPL-2.0
PKG_BUILD_PARALLEL:=0

include $(INCLUDE_DIR)/package.mk

# Sanity check: the mac80211 headers must be in staging (they come from
# package/kernel/mac80211, i.e. `make package/kernel/mac80211/compile`).
MT_STAGING:=$(STAGING_DIR)/usr/include
MT_NOSTDINC:=-nostdinc -I$(MT_STAGING)/mac80211/uapi -I$(MT_STAGING)/mac80211

MT_CFLAGS:= \
	-DRTMP_CFG80211_API_VER=612 \
	-DRTMP_CFG80211_WEXT=0 \
	-DCPTCFG_CFG80211=1 \
	-DCPTCFG_CFG80211_DEBUGFS=1 \
	-DCPTCFG_CFG80211_CERTIFICATION_ONUS=1 \
	-Wno-error

# $(1) = subdir under the build dir (ap|sta), $(2) = WIFI_MODE
#
# KBUILD_EXTRA_SYMBOLS is what lets modpost resolve the cfg80211 symbols.
# OpenWrt normally injects it through KERNEL_MAKE_FLAGS, but this package drives
# the vendor Makefile itself, so the value has to be passed explicitly --
# without it every cfg80211_* / wiphy_* / ieee80211_* symbol is reported
# undefined and the build stops (which is exactly how it failed the first time).
MT_MAKE=+$(MAKE) -C $(PKG_BUILD_DIR)/$(1) \
	WIFI_MODE=$(2) CHIPSET=mt7603u TARGET=LINUX \
	LINUX_SRC="$(LINUX_DIR)" \
	ARCH="$(LINUX_KARCH)" CROSS_COMPILE="$(TARGET_CROSS)" \
	STAGING_DIR="$(STAGING_DIR)" \
	NOSTDINC_FLAGS="$(MT_NOSTDINC)" \
	KBUILD_EXTRA_SYMBOLS="$(wildcard $(PKG_SYMVERS_DIR)/*.symvers)" \
	RTMP_EXTRA_CFLAGS="$(MT_CFLAGS)"

define KernelPackage/mt7603u-ap
  SUBMENU:=Wireless Drivers
  TITLE:=MediaTek MT7603U (360 WiFi 3) USB driver - AP mode
  DEPENDS:=+kmod-cfg80211 +kmod-mac80211 @USB_SUPPORT
  FILES:=$(PKG_BUILD_DIR)/ap/os/linux/mt7603u_ap.ko
  AUTOLOAD:=$(call AutoProbe,mt7603u_ap)
  CONFLICTS:=kmod-mt7603u-sta
endef

define KernelPackage/mt7603u-ap/description
 Vendor driver for the MediaTek MT7603U 2x2 802.11n USB chip (360 WiFi 3,
 USB ID 0e8d:760c), built for access-point operation.  Not usable with
 mac80211's mt7603e (PCIe only) or mt7601u (wrong chip, refuses to probe).
endef

define KernelPackage/mt7603u-sta
  SUBMENU:=Wireless Drivers
  TITLE:=MediaTek MT7603U (360 WiFi 3) USB driver - station mode
  DEPENDS:=+kmod-cfg80211 +kmod-mac80211 @USB_SUPPORT
  FILES:=$(PKG_BUILD_DIR)/sta/os/linux/mt7603u_sta.ko
  AUTOLOAD:=$(call AutoProbe,mt7603u_sta)
  # Deliberately no CONFLICTS here.  Declaring it on both packages makes Kconfig
  # emit "PACKAGE_kmod-mt7603u-ap depends on PACKAGE_kmod-mt7603u-sta" and the
  # reverse, which it rejects as a recursive dependency.  One direction is
  # enough: opkg refuses to install the AP package while the STA one is present,
  # and it also refuses a package whose installed peer conflicts with it.
endef

define KernelPackage/mt7603u-sta/description
 Vendor driver for the MediaTek MT7603U 2x2 802.11n USB chip (360 WiFi 3,
 USB ID 0e8d:760c), built for station (client) operation.
endef

define Package/mt7603u-files
  SECTION:=kernel
  CATEGORY:=Kernel modules
  SUBMENU:=Wireless Drivers
  TITLE:=MT7603U runtime files (firmware + driver config)
  DEPENDS:=+kmod-cfg80211
  PKGARCH:=all
endef

define Package/mt7603u-files/conffiles
/etc/Wireless/RT2870AP/RT2870AP.dat
/etc/Wireless/RT2870AP/RT2870APCard.dat
/etc/Wireless/RT2870STA/RT2870STA.dat
/etc/Wireless/RT2870STA/RT2870STACard.dat
endef

define Package/mt7603u-files/description
 Firmware blobs (MT7603.bin / MT7603_e2.bin) and the vendor's RT2870AP /
 RT2870STA .dat runtime configuration that the MT7603U driver reads when an
 interface is opened.  Marked as conffiles so they survive sysupgrade.
endef

define Build/Prepare
	rm -rf $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src $(PKG_BUILD_DIR)/ap
	$(CP) ./src $(PKG_BUILD_DIR)/sta
	# modpost needs a place to look for symbols exported by packages that are
	# not part of the kernel tree (here: cfg80211).  OpenWrt passes everything
	# in $(PKG_SYMVERS_DIR) to KBUILD_EXTRA_SYMBOLS.
	mkdir -p $(PKG_SYMVERS_DIR)
	$(CP) ./symvers/cfg80211.symvers $(PKG_SYMVERS_DIR)/cfg80211.symvers
	# KernelPackage's post-compile hook greps $(PKG_BUILD_DIR)/Module.symvers;
	# our build writes its symvers under the per-mode subdirs, so give the hook
	# an (empty) file rather than letting it trip over a missing path.
	: > $(PKG_BUILD_DIR)/Module.symvers
endef

define Build/Compile
	$(call MT_MAKE,ap,AP)
	$(call MT_MAKE,sta,STA)
endef

define Package/mt7603u-files/install
	$(INSTALL_DIR) $(1)/lib/firmware/mtk
	$(INSTALL_DATA) ./files/MT7603.bin $(1)/lib/firmware/mtk/MT7603.bin
	$(INSTALL_DATA) ./files/MT7603_e2.bin $(1)/lib/firmware/mtk/MT7603_e2.bin
	$(INSTALL_DIR) $(1)/etc/Wireless/RT2870AP
	$(INSTALL_DATA) ./files/RT2870AP.dat $(1)/etc/Wireless/RT2870AP/RT2870AP.dat
	$(INSTALL_DATA) ./files/RT2870APCard.dat $(1)/etc/Wireless/RT2870AP/RT2870APCard.dat
	$(INSTALL_DIR) $(1)/etc/Wireless/RT2870STA
	$(INSTALL_DATA) ./files/RT2870STA.dat $(1)/etc/Wireless/RT2870STA/RT2870STA.dat
	$(INSTALL_DATA) ./files/RT2870STACard.dat $(1)/etc/Wireless/RT2870STA/RT2870STACard.dat
	$(INSTALL_DIR) $(1)/etc/mt7603u
	$(INSTALL_DATA) ./files/hostapd.conf.example $(1)/etc/mt7603u/hostapd.conf.example
	$(INSTALL_DATA) ./files/wpa_supplicant.conf.example $(1)/etc/mt7603u/wpa_supplicant.conf.example
endef

$(eval $(call KernelPackage,mt7603u-ap))
$(eval $(call KernelPackage,mt7603u-sta))
$(eval $(call BuildPackage,mt7603u-files))
