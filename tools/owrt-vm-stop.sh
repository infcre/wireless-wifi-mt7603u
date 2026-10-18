#!/bin/sh
# Stop the OpenWrt test VM and hand the USB card back to the host.
#
# Stopping QEMU detaches the usb-host device, so the MT7603U returns to the
# Debian host's USB stack.  Nothing will claim it there: the host driver was
# parked during bring-up (see the note at the bottom of this file).

[ -f /root/owrt-vm.pid ] || { echo "no pidfile; not running?"; exit 0; }
PID=$(cat /root/owrt-vm.pid)
kill "$PID" 2>/dev/null
sleep 3
kill -9 "$PID" 2>/dev/null
rm -f /root/owrt-vm.pid
echo "VM stopped"
echo
echo "Card is now on the host.  Its driver is intentionally parked:"
echo "  modules:  /root/mt7603u-host-backup/{mt7603u_ap.ko,mt7603u_sta.ko}"
echo "  autoload: /etc/modules-load.d/mt7603u-sta.conf.disabled"
echo "To use the card on Debian again:"
echo "  mv /lib/modules/\$(uname -r)/extra/  ... (or copy the .ko back),"
echo "  mv /etc/modules-load.d/mt7603u-sta.conf.disabled /etc/modules-load.d/mt7603u-sta.conf,"
echo "  depmod -a && modprobe mt7603u_sta"
