#!/bin/sh
# Post-boot state of the MT7603U inside the VM -- used to prove that the ipk's
# AUTOLOAD entry (/etc/modules.d/mt7603u-*) is enough to bring the driver up on
# a fresh boot, together with its cfg80211 dependency.

echo "=== uptime ==="
uptime
echo "=== lsmod (mt7603/cfg80211/compat) ==="
lsmod | grep -E 'mt7603|cfg80211|compat' || echo "(none loaded)"
echo "=== modules.d entries ==="
for f in /etc/modules.d/mt7603u*; do [ -f "$f" ] && echo "$f: $(cat "$f")"; done
echo "=== interfaces ==="
ip link | grep -E '^[0-9]+:'
echo "=== iw dev ==="
iw dev
echo "=== driver boot messages ==="
dmesg | grep -E 'mt_drv|CFG80211_Register|rtusb init|WiFI FW|Main bssid' | tail -8
echo "=== modinfo (vermagic) ==="
modinfo mt7603u_ap 2>/dev/null | grep -E '^(filename|vermagic|depends)'
echo "=== end ==="