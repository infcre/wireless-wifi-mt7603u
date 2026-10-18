#!/bin/sh
# Validate the built ipk packages inside the VM: install, inspect, and check the
# documented mutual exclusion between the AP and STA packages.
#
# Run with the ipks already scp'd into /tmp/ipk/.

echo "===== 0. drop the hand-deployed modules, leave only the packages' job ====="
rm -f /lib/modules/$(uname -r)/mt7603u_*.ko 2>/dev/null
echo "(removed, will be reinstalled by opkg)"

echo "===== 1. install mt7603u-files + kmod-mt7603u-sta ====="
opkg install /tmp/ipk/mt7603u-files_*_all.ipk /tmp/ipk/kmod-mt7603u-sta_*.ipk 2>&1 | tail -6

echo "===== 2. installed state ====="
opkg list-installed | grep -i mt7603u
echo "--- files package owns: ---"
opkg files mt7603u-files | head -12
echo "--- kmod package owns: ---"
opkg files kmod-mt7603u-sta
echo "--- AUTOLOAD entry ---"
cat /etc/modules.d/mt7603u-sta 2>/dev/null
echo "--- firmware + config in place ---"
ls -l /lib/firmware/mtk/ /etc/Wireless/RT2870STA/

echo "===== 3. conffiles survive removal (opkg's conffiles flag) ====="
sed -n '/conffiles/{n;p;n;p;n;p;n;p}' /usr/lib/opkg/info/mt7603u-files.conffiles 2>/dev/null \
    || cat /usr/lib/opkg/info/mt7603u-files.conffiles 2>/dev/null

echo "===== 4. AP package must refuse to install while STA is present ====="
opkg install /tmp/ipk/kmod-mt7603u-ap_*.ipk 2>&1 | tail -4

echo "===== 5. swap to AP the documented way ====="
opkg remove kmod-mt7603u-sta 2>&1 | tail -2
opkg install /tmp/ipk/kmod-mt7603u-ap_*.ipk 2>&1 | tail -3
opkg list-installed | grep -i mt7603u
ls -l /lib/modules/$(uname -r)/mt7603u_*.ko 2>/dev/null
cat /etc/modules.d/mt7603u-ap 2>/dev/null
echo "===== done ====="