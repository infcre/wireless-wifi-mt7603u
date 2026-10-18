#!/bin/sh
# Start the OpenWrt 24.10.2 x86/64 test VM.
#
# Deliberately mirrors what we will later do on the real router:
#   eth0 -> br-lan, static 192.168.1.1/24, reachable from this host on :2222
#   eth1 -> wan,    DHCP via QEMU user-net, so opkg has internet
#   xhci  -> USB controller; the 360 WiFi 3 stick is attached *later*, live,
#            through the monitor socket, so the VM does not have to be
#            restarted when the hardware is plugged in:
#
#   echo 'device_add usb-host,bus=xhci.0,vendorid=0x0e8d,productid=0x760c' \
#       | socat - UNIX-CONNECT:/root/owrt-vm.mon
#
# Console (ttyS0, the image boots with console=ttyS0,115200n8) is appended to
# /root/owrt-vm-console.log -- the only way to see a panic if the driver
# misbehaves badly enough to take the VM down.

set -e
IMG=/root/owrt-24.10.2/openwrt-24.10.2-x86-64-generic-ext4-combined.img
[ -f "$IMG" ] || { echo "missing $IMG"; exit 1; }

[ -f /root/owrt-vm.pid ] && kill "$(cat /root/owrt-vm.pid)" 2>/dev/null || true
sleep 1

qemu-system-x86_64 \
    -name owrt-mt7603u \
    -enable-kvm -cpu host -m 1024 -smp 2 \
    -drive file="$IMG",format=raw,if=virtio,cache=writeback \
    -netdev user,id=lan,hostfwd=tcp:0.0.0.0:2222-192.168.1.1:22,hostfwd=tcp:0.0.0.0:8081-192.168.1.1:80 \
    -device virtio-net-pci,netdev=lan \
    -netdev user,id=wan,hostfwd=tcp:0.0.0.0:2223-10.0.2.15:22 \
    -device virtio-net-pci,netdev=wan \
    -device qemu-xhci,id=xhci,p2=4,p3=4 \
    -display none \
    -chardev socket,id=ser0,path=/root/owrt-vm.serial,server=on,wait=off,logfile=/root/owrt-vm-console.log \
    -serial chardev:ser0 \
    -monitor unix:/root/owrt-vm.mon,server,nowait \
    -pidfile /root/owrt-vm.pid \
    -daemonize

echo "VM started, pid $(cat /root/owrt-vm.pid)"
echo "console: /root/owrt-vm-console.log   monitor: /root/owrt-vm.mon"
