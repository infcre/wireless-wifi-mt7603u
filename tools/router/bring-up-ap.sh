#!/bin/sh
# Bring the MT7603U up as an AP on a *physical* OpenWrt router, the way that was
# verified on 24.10.2 x86_64 (kernel 6.6.93).
#
# Run it ON the router (it needs modprobe/uci/hostapd there):
#
#   scp bring-up-ap.sh root@192.168.1.1:/tmp/
#   ssh root@192.168.1.1 'sh /tmp/bring-up-ap.sh'
#
# Tunables come from the environment: IF, SSID, PSK, CH, BRIDGE, MODULE.
# It changes no UCI networking state and installs no autoload entry, so a reboot
# returns the box to exactly what it was.
#
# ---------------------------------------------------------------------------
# Three things this script does that are not obvious, each learned the hard way
# ---------------------------------------------------------------------------
#
# 1. `ip link set wlan0 up` must happen *before* hostapd.  Opening the interface
#    is what runs rt28xx_init() -- firmware download, EFUSE MAC read, channel
#    sweep, RF calibration.  Until then the netdev exists but has no MAC
#    (00:00:00:00:00:00) and no usable radio.
#
# 2. hostapd's `bridge=br-lan' must NOT be used with this driver.  On that path
#    hostapd joins the bridge and then issues a separate channel configuration;
#    cfg80211 rejects it as EALREADY and hostapd aborts with
#      Could not set channel for kernel driver
#      Interface initialization failed
#    Start the AP unbridged (the channel then travels inside START_AP) and
#    enslave the interface afterwards with `ip link set master'.
#
# 3. hostapd must be started with -P (pidfile) and killed by PID.  Busybox's
#    `pkill -f' does not reliably match it; a surviving instance keeps its
#    management-frame registrations, and every later hostapd then fails with
#      nl80211: kernel reports: Match already configured   (cfg80211_mlme_register_mgmt)
#    followed by the same "Could not set channel" abort.  One stale process can
#    cost an hour of confusion.
#
# Also worth knowing: OpenWrt's /etc/hotplug.d/ieee80211/10-wifi-detect notices
# the new phy and appends a `radio1' section to /etc/config/wireless (disabled,
# band guessed as 5g).  Delete it, or netifd/LuCI may later try to drive a vendor
# cfg80211 driver as if it were mac80211.

ROUTER=${ROUTER:-root@192.168.1.1}
IF=${IF:-wlan0}
SSID=${SSID:-MT7603U-AP}
PSK=${PSK:-mt7603u12345}
CH=${CH:-11}
BRIDGE=${BRIDGE:-br-lan}
MODULE=${MODULE:-mt7603u_ap}

echo "===== 1. is the module loaded, and is the interface open? ====="
lsmod | grep -q "^$MODULE" || { modprobe "$MODULE" && echo "  loaded $MODULE"; }
ip link set "$IF" up
sleep 10
echo "  MAC: $(cat /sys/class/net/$IF/address)"
dmesg | grep -E "rt28xx_init, Status" | tail -1

echo "===== 2. drop the UCI radio OpenWrt auto-created for this phy ====="
for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.path='.*usb.*'$/\1/p"); do
	echo "  removing wireless.$s (a phy on a USB path is not mac80211)"
	uci -q delete wireless."$s"
done
for s in $(uci show wireless 2>/dev/null | sed -n "s/^wireless\.\([^.]*\)\.device='radio1'$/\1/p"); do
	uci -q delete wireless."$s"
done
uci -q delete wireless.radio1 2>/dev/null
uci commit wireless 2>/dev/null
uci show wireless 2>/dev/null | grep -c radio1 | sed 's/^/  radio1 entries left: /'

echo "===== 3. hostapd, unbridged, with a pidfile ====="
mkdir -p /etc/mt7603u
cat > /etc/mt7603u/hostapd.conf <<EOF
interface=$IF
driver=nl80211
ctrl_interface=/var/run/hostapd-mt7603u
ctrl_interface_group=0

ssid=$SSID
hw_mode=g
channel=$CH
ieee80211n=1
ht_capab=[SHORT-GI-20]
wmm_enabled=1

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
wpa_passphrase=$PSK

logger_syslog=-1
logger_syslog_level=2
logger_stdout=1
logger_stdout_level=2
EOF

# kill every previous instance, by PID (see note 3)
for p in $(ps | grep "[h]ostapd .*mt7603u" | awk '{print $1}'); do kill "$p" 2>/dev/null; done
sleep 2
rm -rf /var/run/hostapd-mt7603u
rm -f /tmp/hostapd-mt7603u.log
setsid hostapd -P /var/run/hostapd-mt7603u.pid /etc/mt7603u/hostapd.conf >/tmp/hostapd-mt7603u.log 2>&1 &
sleep 12
grep -q "AP-ENABLED" /tmp/hostapd-mt7603u.log \
	&& echo "  AP-ENABLED" \
	|| { echo "  FAILED:"; cat /tmp/hostapd-mt7603u.log; exit 1; }

echo "===== 4. bridge it into the LAN (DHCP + firewall + NAT come for free) ====="
ip link set "$IF" master "$BRIDGE"
sleep 9
echo "  ports: $(ls /sys/class/net/$BRIDGE/brif/ | tr '\n' ' ')"
echo "  port state: $(cat /sys/class/net/$IF/brport/state)  (3=forwarding)"

echo "===== 5. summary ====="
iw dev "$IF" info | grep -E "ssid|type|addr"
ip -br addr show "$BRIDGE"
echo "  clients get a lease from the router's own dnsmasq and internet via the"
echo "  existing lan->wan masquerade -- nothing else to configure."
echo
echo "  NOTE: none of this survives a reboot yet (no autoload entry).  See"
echo "  openwrt/README.md for making it persistent."