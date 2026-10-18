#!/bin/sh
# Run a command on the OpenWrt VM's serial console (root, no password) and show
# the result.  Used instead of SSH when the guest's network is not answering --
# in particular while bringing up a driver that can wedge the network stack.
#
#   owrt-vm-sh.sh 'uname -a'
#   owrt-vm-sh.sh 'dmesg | tail -30'
#
# The image boots with console=ttyS0,115200n8 and QEMU exposes that console as
# a unix socket (see owrt-vm-start.sh), so this is a real interactive session.
# A hard timeout keeps a wedged guest from hanging the caller forever.

SOCK=/root/owrt-vm.serial
TIMEOUT="${OWRT_SERIAL_TIMEOUT:-40}"

[ -S "$SOCK" ] || { echo "no serial socket $SOCK"; exit 1; }

{
    printf '\n'
    sleep 1
    # login prompt: root has no password in the image
    printf 'root\n'
    sleep 2
    printf '%s\n' "$*"
    sleep 3
    printf 'exit\n'
} | timeout "$TIMEOUT" socat - UNIX-CONNECT:"$SOCK" 2>&1
