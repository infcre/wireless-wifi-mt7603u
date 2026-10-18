#!/bin/sh
# Run a shell script on a remote Debian/Armbian box over SSH.
#
#   tools/debian/ssh-run.sh remote/sta-connect.sh
#   tools/debian/ssh-run.sh -c 'uname -a; iw dev'
#
# Configuration comes from the environment (see ../../.env.example):
#
#   DEBIAN_HOST   user@host        e.g. root@192.168.1.10
#   DEBIAN_KEY    private key      optional; omit to use ssh-agent/default keys
#
# The script content is piped to `bash -s` on the far side, so no shell quoting
# survives on this side -- the same trick the bring-up used, because quoting a
# multi-line bash script through PowerShell/cmd is where the time goes.
#
# NOTE (a trap worth remembering): if a script delivered this way itself calls
# ssh/scp, that inner command must be given -n or </dev/null.  Otherwise it reads
# *this* stream and silently eats the rest of the script.

set -e
HERE=$(cd "$(dirname "$0")" && pwd)

[ -n "$DEBIAN_HOST" ] || { echo "set DEBIAN_HOST (see ../../.env.example)"; exit 2; }

KEYOPT=
[ -n "$DEBIAN_KEY" ] && KEYOPT="-i $DEBIAN_KEY"

if [ "$1" = "-c" ]; then
	shift
	PAYLOAD=$1
else
	[ -f "$1" ] || { echo "usage: $0 <script.sh> | -c '<commands>'"; exit 2; }
	PAYLOAD=$(cat "$1")
fi

# No -n here: this ssh must read the payload from the pipe and hand it to
# `bash -s` on the far side.  (-n belongs on ssh/scp calls *inside* the payload.)
# shellcheck disable=SC2086
printf '%s\n' "$PAYLOAD" | ssh $KEYOPT \
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o BatchMode=yes -o LogLevel=ERROR \
	"$DEBIAN_HOST" "bash -s"