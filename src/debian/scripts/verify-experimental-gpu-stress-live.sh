#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

target=${1:-}
gpu_hz=${2:-}
seconds=${3:-}
[ -n "$target" ] && [ -n "$gpu_hz" ] && [ -n "$seconds" ] || {
	echo "usage: $0 SSH_TARGET EXPECTED_GPU_HZ SECONDS" >&2
	exit 2
}
case "$gpu_hz:$seconds" in *[!0-9:]*|:*) echo invalid-argument >&2; exit 2 ;; esac
[ "$seconds" -ge 10 ] && [ "$seconds" -le 900 ] || {
	echo duration-out-of-range >&2
	exit 2
}

ssh -o BatchMode=yes -o ConnectTimeout=6 "$target" sh -s -- "$gpu_hz" "$seconds" <<'REMOTE'
set -eu
gpu_hz=$1
seconds=$2
fail() { echo "M1892_GPU_STRESS_FAIL: $*" >&2; exit 1; }
[ "$(tr -d '\0' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] || fail model
desktop_uid=$(loginctl list-sessions --no-legend |
	awk '$3 != "root" && $4 == "seat0" { print $2; exit }')
[ -n "$desktop_uid" ] || fail desktop-user-not-found
pgrep -u "$desktop_uid" -x glmark2-wayland >/dev/null || fail glmark-not-running
dev=/sys/class/devfreq/5000000.gpu
grep -qw "$gpu_hz" "$dev/available_frequencies" || fail target-not-registered
if dmesg | grep -Ei 'EXT4-fs error|I/O error|gpu fault|ring.*hang|IOMMU.*fault' |
	grep -vi 'Default domain' | grep -q .; then
	fail preexisting-kernel-fault
fi
old_max=$(cat "$dev/max_freq")
lowest=$(tr ' ' '\n' <"$dev/available_frequencies" | sort -n | head -1)
[ "$gpu_hz" -le "$old_max" ] || fail "target-above-max:$gpu_hz/$old_max"
restore() {
	echo "$old_max" >"$dev/max_freq" 2>/dev/null || true
	echo "$lowest" >"$dev/min_freq" 2>/dev/null || true
}
trap restore EXIT HUP INT TERM
echo "$gpu_hz" >"$dev/max_freq"
echo "$gpu_hz" >"$dev/min_freq"
log=$(mktemp /tmp/m1892-gpu-stress.XXXXXXXX.tsv)
i=1
while [ "$i" -le "$seconds" ]; do
	freq=$(cat "$dev/cur_freq")
	temp=$(cat /sys/class/thermal/thermal_zone*/temp | sort -nr | head -1)
	printf '%s\t%s\t%s\n' "$i" "$freq" "$temp" >>"$log"
	[ "$temp" -lt 85000 ] || fail "temperature-mC:$temp"
	if dmesg | grep -Ei 'EXT4-fs error|I/O error|gpu fault|ring.*hang|IOMMU.*fault' |
		grep -vi 'Default domain' | grep -q .; then
		fail kernel-fault
	fi
	i=$((i + 1))
	sleep 1
done
hits=$(cut -f2 "$log" | grep -cx "$gpu_hz" || true)
minimum=$((seconds * 9 / 10))
[ "$hits" -ge "$minimum" ] || fail "residency:$hits/$seconds"
printf 'frequency_counts\n'
cut -f2 "$log" | sort | uniq -c
printf 'max_temp_mC='
cut -f3 "$log" | sort -nr | head -1
printf 'target_samples=%s/%s\n' "$hits" "$seconds"
printf 'failed_units='
systemctl --failed --no-legend | wc -l
rm -f "$log"
restore
trap - EXIT HUP INT TERM
# A busy DRM client may immediately raise the devfreq minimum again through
# the kernel's workload boost.  The caller stops that client, then verifies
# the final idle range; checking it here would race the active workload.
echo M1892_GPU_STRESS_PASS
exit 0
REMOTE
