#!/bin/sh
# Associate the MT7603U in STA mode from inside the VM, then measure it.
#
# Prerequisites (already done by the AP->STA switch):
#   - mt7603u_ap unloaded, USB interface unbound from mt_drv
#
# Rigour notes:
#   - ping uses -I wlan0 and iperf3 uses -B <sta-ip>; without that, traffic to
#     192.168.1.1 leaves through the VM's *wan* (QEMU user-net -> host wifi ->
#     real router) and the numbers would say nothing about the MT7603U.
#   - "ip route get" is printed so the path is documented, not assumed.

IF=${IF:-wlan0}
SSID=${SSID:-OpenWrt}
PSK=${PSK:?set PSK of the upstream AP (see .env.example)}
DAT=/etc/Wireless/RT2870STA/RT2870STA.dat
K=$(uname -r)

echo "===== 1. load the STA module ====="
insmod "/lib/modules/$K/mt7603u_sta.ko"
echo "insmod_rc=$?"
sleep 4
if [ ! -d /sys/class/net/$IF ]; then
    echo "(no $IF yet -- binding the USB interface to mt_drv)"
    for f in /sys/bus/usb/drivers/mt_drv/1-1*; do
        [ -d "$f" ] && echo -n "$(basename "$f")" > /sys/bus/usb/drivers/mt_drv/bind
    done
    sleep 6
fi
dmesg | tail -12
ip link set "$IF" up
sleep 6
echo "--- wiphy modes ---"
iw phy phy0 info 2>/dev/null | sed -n '/Supported interface modes/,/Band 1/p' | head -8

echo "===== 2. wpa_supplicant ====="
cat > /tmp/wpa-mt7603u.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
ap_scan=1
network={
	ssid="$SSID"
	psk="$PSK"
}
EOF
kill "$(cat /var/run/wpa_supplicant-mt7603u.pid 2>/dev/null)" 2>/dev/null
sleep 1
wpa_supplicant -B -i "$IF" -c /tmp/wpa-mt7603u.conf -P /var/run/wpa_supplicant-mt7603u.pid
sleep 15
wpa_cli -i "$IF" status 2>/dev/null | grep -E "^(wpa_state|ssid|bssid|freq|key_mgmt|pairwise_cipher)"
echo "--- iw link ---"
iw dev "$IF" link
iw dev "$IF" info | grep -E "ssid|channel|type|addr"

echo "===== 3. DHCP ====="
udhcpc -i "$IF" -n -q -t 6 -T 3 2>&1 | tail -3
ip addr show "$IF" | grep "inet "
STAIP=$(ip addr show "$IF" | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' | head -1)
echo "STA IP: $STAIP"
echo "--- route to the real router ---"
ip route get 192.168.1.1

echo "===== 4. connectivity (pinned to $IF) ====="
ping -I "$IF" -c 10 192.168.1.1 | tail -3

echo "===== 5. throughput (iperf3 against the real router) ====="
command -v iperf3 >/dev/null || { echo "installing iperf3"; opkg install iperf3 >/dev/null 2>&1; }
if command -v iperf3 >/dev/null; then
    echo "--- TX (STA -> router) ---"
    iperf3 -c 192.168.1.1 -B "$STAIP" -t 8 -O 2 2>&1 | tail -4
    echo "--- RX (router -> STA) ---"
    iperf3 -c 192.168.1.1 -B "$STAIP" -t 8 -O 2 -R 2>&1 | tail -4
else
    echo "iperf3 unavailable"
fi

echo "===== 6. churn check (60 s) ====="
N0=$(dmesg | grep -c "PeerBeaconAtJoinAction")
sleep 60
N1=$(dmesg | grep -c "PeerBeaconAtJoinAction")
echo "re-joins during 60 s: $((N1 - N0))"
iw dev "$IF" link | head -6