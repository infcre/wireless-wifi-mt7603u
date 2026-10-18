#!/bin/sh
# Build the MT7603U vendor driver against the *host's* kernel headers and
# install it.  Works on Debian (x86_64) and on Armbian (aarch64) unchanged --
# the driver has no architecture-specific code of its own.
#
#   tools/debian/build.sh ap        # build + install the AP module
#   tools/debian/build.sh sta       # ... the STA module
#   tools/debian/build.sh ap --no-install
#
# Prerequisites:
#   sudo apt install build-essential linux-headers-$(uname -r)
#
# The module is installed as /lib/modules/$(uname -r)/extra/mt7603u_<mode>.ko and
# its runtime files under /lib/firmware/mtk and /etc/Wireless, i.e. exactly the
# layout described in docs/debian-bringup/REPORT.md.
#
# Two operational rules from that report, which this script respects:
#   * never call the vendor's private ioctls (iwpriv ...) -- one such call wedged
#     a host with RTNL and module_mutex held forever;
#   * do not rmmod this driver while the stick is bound.  To switch modes:
#       ip link set <if> down
#       echo -n <busid> > /sys/bus/usb/drivers/mt_drv/unbind     # e.g. 1-4:1.0
#       rmmod mt7603u_<old>;  insmod/install the other one
#     Rebooting is always the safer option on a machine you cannot reach.

set -e

MODE=$(echo "${1:-ap}" | tr 'A-Z' 'a-z')
case "$MODE" in
	ap|sta) ;;
	*) echo "usage: $0 ap|sta [--no-install]"; exit 2 ;;
esac
INSTALL=yes
[ "$2" = "--no-install" ] && INSTALL=no

HERE=$(cd "$(dirname "$0")" && pwd)
DPOA=$(cd "$HERE/../../DPOA" && pwd)
KREL=$(uname -r)
KBUILD=/lib/modules/$KREL/build

[ -d "$KBUILD" ] || {
	echo "no kernel headers at $KBUILD"
	echo "  sudo apt install linux-headers-$KREL"
	exit 1
}

echo "=== building mt7603u_$MODE for $KREL ($(uname -m)) ==="
make -C "$DPOA" WIFI_MODE=$(echo "$MODE" | tr 'a-z' 'A-Z') CHIPSET=mt7603u \
	TARGET=LINUX LINUX_SRC="$KBUILD" 2>&1 | tail -20

KO="$DPOA/os/linux/mt7603u_$MODE.ko"
[ -f "$KO" ] || { echo "build produced no $KO"; exit 1; }
echo "=== built: $(ls -l "$KO" | awk '{print $5}') bytes ==="
modinfo "$KO" | grep -E '^(vermagic|depends|license)'

if [ "$INSTALL" != yes ]; then
	echo "(--no-install) module left at $KO"
	exit 0
fi

echo "=== installing ==="
install -d "/lib/modules/$KREL/extra"
install -m 644 "$KO" "/lib/modules/$KREL/extra/"
depmod -a

install -d /lib/firmware/mtk
install -m 644 "$DPOA/mcu/bin/WIFI_RAM_CODE_MT7603_e1.bin" /lib/firmware/mtk/MT7603.bin
install -m 644 "$DPOA/mcu/bin/WIFI_RAM_CODE_MT7603_e2.bin" /lib/firmware/mtk/MT7603_e2.bin

# Vendor runtime config.  The .dat is read every time the interface is opened.
# The three settings that matter for the STA side are pre-applied here:
#   SSID=              (empty -- otherwise wpa_supplicant's choice is overridden)
#   HT_BW=0            20 MHz measured better than 40 MHz on a busy band
#   BeaconLostTime=30  the vendor default of 4 causes a reassociation every ~12 s
install -d /etc/Wireless/RT2870AP /etc/Wireless/RT2870STA
for f in RT2870AP.dat RT2870APCard.dat; do
	[ -f "/etc/Wireless/RT2870AP/$f" ] || install -m 644 "$DPOA/$f" /etc/Wireless/RT2870AP/
done
for f in RT2870STA.dat RT2870STACard.dat; do
	[ -f "/etc/Wireless/RT2870STA/$f" ] || install -m 644 "$DPOA/$f" /etc/Wireless/RT2870STA/
done
sed -i 's/^SSID=.*/SSID=/'                          /etc/Wireless/RT2870STA/RT2870STA.dat
sed -i 's/^HT_BW=.*/HT_BW=0/'                       /etc/Wireless/RT2870STA/RT2870STA.dat
sed -i 's/^BeaconLostTime=.*/BeaconLostTime=30/'    /etc/Wireless/RT2870STA/RT2870STA.dat

cat <<EOF

installed:
  /lib/modules/$KREL/extra/mt7603u_$MODE.ko
  /lib/firmware/mtk/MT7603{,_e2}.bin
  /etc/Wireless/RT2870{AP,STA}/*.dat

load it:
  sudo modprobe mt7603u_$MODE        # or: insmod /lib/modules/$KREL/extra/mt7603u_$MODE.ko
  dmesg | tail                       # expect: rtusb init mt_drv ... CFG80211_Register
  iw dev                             # the interface appears as wlanX / wlx<mac>

then, for AP mode:  hostapd -B <config>   (see the .example files in the OpenWrt package)
     for STA mode:  wpa_supplicant -B -i <if> -c <config>;  udhcpc/dhclient <if>
EOF