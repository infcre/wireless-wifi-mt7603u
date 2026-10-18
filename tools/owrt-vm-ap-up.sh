#!/bin/sh
# Bring the MT7603U up as an access point inside the test VM.
#
# Kept on its own subnet (192.168.77.0/24) on purpose: br-lan already sits on
# 192.168.1.0/24, which is the *real* LAN's subnet, and mixing the test AP into
# it makes every routing/ARP question ambiguous.  A separate subnet means the
# client gets an unambiguous lease and can be pinged directly.
#
# Also runs a private dnsmasq bound to wlan0 (the image's main dnsmasq keeps
# serving br-lan on 192.168.1.1).

IF=${IF:-wlan0}
S=${SUBNET:-192.168.77}
PSK=${PSK:-mt7603u12345}
SSID=${SSID:-MT7603U-AP}
CH=${CH:-11}

ap_stop() {
    kill "$(cat /var/run/hostapd-mt7603u.pid 2>/dev/null)" 2>/dev/null
    kill "$(cat /var/run/dnsmasq-mt7603u.pid 2>/dev/null)" 2>/dev/null
    sleep 1
}

ap_stop

ip link set "$IF" down 2>/dev/null
ip addr flush dev "$IF" 2>/dev/null
ip addr add "$S.1/24" dev "$IF"
ip link set "$IF" up
sleep 2

cat > /tmp/hostapd-mt7603u.conf <<EOF
interface=$IF
driver=nl80211
ctrl_interface=/var/run/hostapd
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

hostapd -B -P /var/run/hostapd-mt7603u.pid /tmp/hostapd-mt7603u.conf
RC=$?
sleep 3
echo "=== hostapd rc=$RC ==="
echo "=== iw dev $IF info ==="
iw dev "$IF" info
echo "=== dmesg tail ==="
dmesg | tail -10

dnsmasq --conf-file=/dev/null -i "$IF" --bind-interfaces \
    --dhcp-range="$S.100,$S.200,255.255.255.0,12h" \
    --dhcp-option=3,"$S.1" --dhcp-option=6,"$S.1" \
    --pid-file=/var/run/dnsmasq-mt7603u.pid
echo "=== dnsmasq pid: $(cat /var/run/dnsmasq-mt7603u.pid 2>/dev/null) ==="
echo "=== wlan0 addr ==="
ip -br addr show "$IF"
