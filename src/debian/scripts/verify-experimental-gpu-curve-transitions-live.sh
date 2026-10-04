#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

target=${1:-}
cycles=${2:-10}
[ -n "$target" ] || {
	echo "usage: $0 SSH_TARGET [CYCLES]" >&2
	exit 2
}
case "$cycles" in *[!0-9]*|'') echo invalid-cycles >&2; exit 2 ;; esac
[ "$cycles" -ge 1 ] && [ "$cycles" -le 30 ] || {
	echo cycles-out-of-range >&2
	exit 2
}

ssh -o BatchMode=yes -o ConnectTimeout=6 "$target" sh -s -- "$cycles" <<'REMOTE'
set -eu
cycles=$1
fail() { echo "M1892_GPU_CURVE_TRANSITION_FAIL: $*" >&2; exit 1; }
[ "$(tr -d '\0' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] || fail model
desktop_uid=$(loginctl list-sessions --no-legend |
	awk '$3 != "root" && $4 == "seat0" { print $2; exit }')
[ -n "$desktop_uid" ] || fail desktop-user-not-found
pgrep -u "$desktop_uid" -x glmark2-wayland >/dev/null || fail glmark-not-running
dev=/sys/class/devfreq/5000000.gpu
expected='257000000 342000000 414000000 520000000 596000000 675000000 710000000 750000000 825000000'
[ "$(cat "$dev/available_frequencies")" = "$expected" ] || fail frequency-table
if dmesg | grep -Ei 'EXT4-fs error|I/O error|gpu fault|ring.*hang|IOMMU.*fault' |
	grep -vi 'Default domain' | grep -q .; then
	fail preexisting-kernel-fault
fi
old_max=$(cat "$dev/max_freq")
lowest=257000000
restore() {
	echo "$old_max" >"$dev/max_freq" 2>/dev/null || true
	echo "$lowest" >"$dev/min_freq" 2>/dev/null || true
}
trap restore EXIT HUP INT TERM
sequence='257000000 342000000 414000000 520000000 596000000 675000000 710000000 750000000 825000000 750000000 710000000 675000000 596000000 520000000 414000000 342000000'
max_temp=0
samples=0
cycle=1
while [ "$cycle" -le "$cycles" ]; do
	for freq in $sequence; do
		echo "$freq" >"$dev/max_freq"
		echo "$freq" >"$dev/min_freq"
		sleep 1
		actual=$(cat "$dev/cur_freq")
		[ "$actual" = "$freq" ] || fail "frequency:$cycle:$freq:$actual"
		temp=$(cat /sys/class/thermal/thermal_zone*/temp | sort -nr | head -1)
		[ "$temp" -lt 85000 ] || fail "temperature-mC:$temp"
		[ "$temp" -le "$max_temp" ] || max_temp=$temp
		if dmesg | grep -Ei 'EXT4-fs error|I/O error|gpu fault|ring.*hang|IOMMU.*fault' |
			grep -vi 'Default domain' | grep -q .; then
			fail "kernel-fault:$cycle:$freq"
		fi
		samples=$((samples + 1))
	done
	cycle=$((cycle + 1))
done
restore
trap - EXIT HUP INT TERM
printf 'cycles=%s\n' "$cycles"
printf 'transition_samples=%s\n' "$samples"
printf 'max_temp_mC=%s\n' "$max_temp"
printf 'failed_units='
systemctl --failed --no-legend | wc -l
echo M1892_GPU_CURVE_TRANSITION_PASS
exit 0
REMOTE
