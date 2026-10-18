#!/bin/sh
# Prepare the OpenWrt 24.10.2 x86/64 ext4 image for use as a QEMU/KVM test VM.
#
#   - key-based SSH for root (Debian's own key)
#   - a known root password as a fallback
#   - a second NIC (eth1) as WAN with DHCP, so the VM has internet for opkg
#     while br-lan stays at 192.168.1.1/24 exactly like a stock install
#
# Offsets come from fdisk on the combined image:
#   p1 @ 512      (16M, /boot)
#   p2 @ 33792    (ext4 rootfs, 512-byte units)  -> byte offset 33792*512
set -e

IMG=/root/owrt-24.10.2/openwrt-24.10.2-x86-64-generic-ext4-combined.img
OFF=$((33792 * 512))
MNT=/mnt/owrt

mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mount -o loop,offset=$OFF "$IMG" "$MNT"

# --- SSH access -------------------------------------------------------------
mkdir -p "$MNT/etc/dropbear"
cp -f /root/.ssh/id_ed25519.pub "$MNT/etc/dropbear/authorized_keys"
chmod 600 "$MNT/etc/dropbear/authorized_keys"

# root password for the VM comes from $VM_PASS (see .env.example); it is a
# throwaway value for a local VM, never a real credential.
HASH=$(openssl passwd -6 "${VM_PASS:-openwrt-test}")
sed -i "s|^root:[^:]*:|root:$HASH:|" "$MNT/etc/shadow"
grep -q '^root:' "$MNT/etc/shadow" && echo "shadow updated"

# --- networking: keep br-lan static, add DHCP WAN on eth1 -------------------
if ! grep -q "config interface 'wan'" "$MNT/etc/config/network"; then
    cat >> "$MNT/etc/config/network" <<'EOF'

config interface 'wan'
	option device 'eth1'
	option proto 'dhcp'
EOF
fi
cat "$MNT/etc/config/network"

# --- opkg: point at a fast mirror (the VM has to fetch kmod-cfg80211 etc.) --
sed -i 's|https\?://downloads.openwrt.org|https://mirrors.aliyun.com/openwrt|g' \
    "$MNT/etc/opkg/distfeeds.conf" 2>/dev/null || true
cat "$MNT/etc/opkg/distfeeds.conf" 2>/dev/null | head -6

sync
umount "$MNT"
echo "IMAGE READY: $IMG"
