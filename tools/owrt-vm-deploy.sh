#!/bin/sh
# Deploy the freshly built MT7603U modules + runtime files into the OpenWrt
# test VM by hand -- i.e. exactly the file layout the ipk installs, but without
# waiting for the package build.
#
#   mt7603u_ap.ko / mt7603u_sta.ko  -> /lib/modules/$(uname -r)/
#   MT7603*.bin                     -> /lib/firmware/mtk/
#   RT2870AP*.dat / RT2870STA*.dat  -> /etc/Wireless/RT2870AP|STA/
#
# scp uses -O (legacy SCP protocol): the VM runs dropbear without
# openssh-sftp-server, so the modern SFTP-based scp cannot be used.

set -e

APK=/root/owrt-build/work-AP/DPOA/os/linux/mt7603u_ap.ko
STAK=/root/owrt-build/work-STA/DPOA/os/linux/mt7603u_sta.ko
F=/root/owrt-pkg/mt7603u/files

SCP="sshpass -p ${VM_PASS:?set VM_PASS} scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -P 2223"
SSH="/root/owrt-vm-ssh.sh"

[ -f "$APK" ]  || { echo "missing $APK"; exit 1; }
[ -f "$STAK" ] || { echo "missing $STAK"; exit 1; }

$SSH 'mkdir -p /lib/firmware/mtk /etc/Wireless/RT2870AP /etc/Wireless/RT2870STA /tmp/mt76'

$SCP "$APK" "$STAK" root@127.0.0.1:/tmp/mt76/
$SCP "$F/MT7603.bin" "$F/MT7603_e2.bin" root@127.0.0.1:/lib/firmware/mtk/
$SCP "$F/RT2870AP.dat" "$F/RT2870APCard.dat" root@127.0.0.1:/etc/Wireless/RT2870AP/
$SCP "$F/RT2870STA.dat" "$F/RT2870STACard.dat" root@127.0.0.1:/etc/Wireless/RT2870STA/

$SSH 'K=$(uname -r); cp /tmp/mt76/*.ko /lib/modules/$K/; depmod -a; sync; echo "--- installed ---"; ls -l /lib/modules/$K/mt7603u_*.ko /lib/firmware/mtk/ /etc/Wireless/RT2870AP/'

echo "DEPLOY OK"