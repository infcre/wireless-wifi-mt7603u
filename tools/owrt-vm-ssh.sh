#!/bin/sh
# Run a command inside the OpenWrt test VM over SSH.
#
#   owrt-vm-ssh.sh 'uname -a'
#   owrt-vm-ssh.sh < some-script.sh
#
# Reaches the guest through the *wan* QEMU user-net (127.0.0.1:2223 ->
# 10.0.2.15:22), not through the LAN one.  Both user-netdevs live in
# 10.0.2.0/24, so a LAN-side hostfwd to 192.168.1.1 answers its SYN with a
# packet the guest routes out of its wan interface, where the lan-side slirp
# never sees it -- the connection then dies during banner exchange.  Going in
# through wan keeps the reply on the interface the connection arrived on.
#
# The guest's firewall is opened once for wan:22 (see notes / uci rule
# "Allow-SSH-WAN").

PORT=${VM_PORT:-2223}
HOST=${VM_HOST:-127.0.0.1}
PASS=${VM_PASS:?set VM_PASS (see .env.example)}

exec sshpass -p "$PASS" ssh -n \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR -o ConnectTimeout=15 \
    -p "$PORT" "root@$HOST" "$@"