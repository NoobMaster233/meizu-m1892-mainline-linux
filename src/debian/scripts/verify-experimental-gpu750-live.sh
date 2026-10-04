#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

target=${1:-}
[ -n "$target" ] || {
	echo "usage: $0 SSH_TARGET" >&2
	exit 2
}

ssh -o BatchMode=yes -o ConnectTimeout=6 "$target" sh -s <<'REMOTE'
set -eu
fail() { echo "M1892_GPU750_LIVE_FAIL: $*" >&2; exit 1; }
model=$(tr -d '\0' </sys/firmware/devicetree/base/model)
[ "$model" = 'Meizu 16th Plus (M1892)' ] || fail "model:$model"
grep -Fq 'Debian GNU/Linux 13' /etc/os-release || fail release
opp=/proc/device-tree/soc@0/gpu@5000000/opp-table/opp-750000000
[ -d "$opp" ] || fail opp750-dt-absent
python3 - "$opp" <<'PY'
import pathlib
import struct
import sys

opp = pathlib.Path(sys.argv[1])
hz = struct.unpack(">Q", opp.joinpath("opp-hz").read_bytes())[0]
level = struct.unpack(">I", opp.joinpath("opp-level").read_bytes())[0]
bw = struct.unpack(">I", opp.joinpath("opp-peak-kBps").read_bytes())[0]
if (hz, level, bw) != (750_000_000, 416, 7_216_000):
    raise SystemExit(f"opp-contract:{hz}:{level}:{bw}")
PY
devfreq=/sys/class/devfreq/5000000.gpu
[ -d "$devfreq" ] || fail gpu-devfreq
grep -qw 750000000 "$devfreq/available_frequencies" || fail freq-not-registered
[ "$(cat "$devfreq/max_freq")" = 750000000 ] || fail max-freq
[ "$(cat /sys/devices/system/cpu/cpufreq/boost)" = 1 ] || fail cpu-stock-boost
max_temp=$(cat /sys/class/thermal/thermal_zone*/temp | sort -nr | head -1)
[ "$max_temp" -lt 85000 ] || fail "temperature-mC:$max_temp"
[ "$(systemctl --failed --no-legend | wc -l)" -eq 0 ] || fail failed-units
if dmesg | grep -Ei 'EXT4-fs error|I/O error|gpu fault|ring.*hang|IOMMU.*fault' |
	grep -vi 'Default domain' | grep -q .; then
	fail kernel-fault
fi
printf 'model=%s\n' "$model"
printf 'gpu_available_frequencies=%s\n' "$(cat "$devfreq/available_frequencies")"
printf 'gpu_max_freq=%s\n' "$(cat "$devfreq/max_freq")"
printf 'cpu_boost=%s\n' "$(cat /sys/devices/system/cpu/cpufreq/boost)"
printf 'max_temp_mC=%s\n' "$max_temp"
echo M1892_GPU750_LIVE_PASS
REMOTE
