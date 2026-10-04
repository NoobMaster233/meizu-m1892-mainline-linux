#!/bin/sh
# SPDX-License-Identifier: MIT
# Capture the current M1892 Plasma workspace through an authenticated SSH path.
set -eu

target=${1:-}
output=${2:-}
fail() { printf 'M1892_PLASMA_CAPTURE_FAIL: %s\n' "$*" >&2; exit 1; }

[ -n "$target" ] && [ -n "$output" ] || {
	printf 'usage: %s root@HOST /absolute/output.png\n' "$0" >&2
	exit 2
}
case "$output" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output" ] && [ ! -e "$output.part" ] || fail output-exists
for command in ssh scp sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "command:$command"
done

model=$(ssh "$target" 'tr -d "\000" </sys/firmware/devicetree/base/model')
[ "$model" = 'Meizu 16th Plus (M1892)' ] || fail device-identity
remote=/tmp/m1892-plasma-workspace-$$.png
cleanup() {
	rm -f "$output.part"
	ssh "$target" "rm -f '$remote' '$remote.log'" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

result=$(ssh "$target" sh -s -- "$remote" <<'REMOTE'
set -eu
output=$1
owner=$(sed -n 's/^owner=//p' /var/lib/m1892/oem-owner-created 2>/dev/null)
[ -n "$owner" ] && uid=$(id -u "$owner") && home=$(getent passwd "$owner" | cut -d: -f6)
[ -n "${uid:-}" ] && [ -d "${home:-}" ] && [ -S "/run/user/$uid/wayland-0" ] || exit 1
rm -f "$output" "$output.log"
for attempt in 1 2 3; do
	pkill -u "$uid" -x spectacle 2>/dev/null || true
	runuser -u "$owner" -- env \
		HOME="$home" USER="$owner" LOGNAME="$owner" \
		XDG_RUNTIME_DIR="/run/user/$uid" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
		WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland \
		spectacle -i -f -b -n -o "$output" >"$output.log" 2>&1 || true
	[ -s "$output" ] && break
	sleep 2
done
[ -s "$output" ] || {
	tail -20 "$output.log" >&2
	exit 1
}
printf '%s %s\n' "$(sha256sum "$output" | awk '{print $1}')" "$(stat -c %s "$output")"
REMOTE
) || fail device-capture
set -- $result
remote_hash=${1:-}
remote_bytes=${2:-}
case "$remote_hash" in ''|*[!0-9a-f]*) fail receipt-hash ;; esac
[ "${#remote_hash}" = 64 ] || fail receipt-hash-length
case "$remote_bytes" in ''|*[!0-9]*) fail receipt-size ;; esac
scp "$target:$remote" "$output.part" >/dev/null
[ "$(stat -c %s "$output.part")" = "$remote_bytes" ] || fail transfer-size
[ "$(sha256sum "$output.part" | awk '{print $1}')" = "$remote_hash" ] || fail transfer-hash
mv "$output.part" "$output"
trap - EXIT HUP INT TERM
ssh "$target" "rm -f '$remote' '$remote.log'" >/dev/null 2>&1 || true
printf 'capture=%s\nbytes=%s\nsha256=%s\nM1892_PLASMA_CAPTURE_PASS\n' \
	"$output" "$remote_bytes" "$remote_hash"
