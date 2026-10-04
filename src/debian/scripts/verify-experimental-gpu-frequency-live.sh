#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

target=${1:-}
gpu_hz=${2:-}
gpu_level=${3:-416}
curve_spec=${4:-none}
gpu_intermediate_level=${5:-416}
[ -n "$target" ] && [ -n "$gpu_hz" ] || {
	echo "usage: $0 SSH_TARGET EXPECTED_GPU_HZ [EXPECTED_GPU_LEVEL] [CURVE_SPEC] [EXPECTED_GPU_750_LEVEL]" >&2
	exit 2
}
case "$gpu_hz" in *[!0-9]*|'') echo invalid-frequency >&2; exit 2 ;; esac

case "$gpu_level" in 384|416) ;; *) echo invalid-level >&2; exit 2 ;; esac
case "$gpu_intermediate_level" in 320|384|416) ;; *) echo invalid-750-level >&2; exit 2 ;; esac
python3 - "$curve_spec" <<'PY'
import sys

spec = sys.argv[1]
allowed = {
    "257000000:16", "257000000:48", "342000000:48", "342000000:64",
    "414000000:64", "414000000:128", "520000000:128", "520000000:192",
    "596000000:192", "596000000:256", "675000000:256", "675000000:320",
    "710000000:320", "710000000:384",
}
if spec == "none":
    raise SystemExit(0)
items = spec.split(",")
if len(items) != len(set(items)) or any(item not in allowed for item in items):
    raise SystemExit("unsupported-curve-spec")
PY

ssh -o BatchMode=yes -o ConnectTimeout=6 "$target" sh -s -- "$gpu_hz" "$gpu_level" "$curve_spec" "$gpu_intermediate_level" <<'REMOTE'
set -eu
gpu_hz=$1
gpu_level=$2
curve_spec=$3
gpu_intermediate_level=$4
fail() { echo "M1892_GPU_FREQUENCY_LIVE_FAIL: $*" >&2; exit 1; }
model=$(tr -d '\0' </sys/firmware/devicetree/base/model)
[ "$model" = 'Meizu 16th Plus (M1892)' ] || fail "model:$model"
grep -Fq 'Debian GNU/Linux 13' /etc/os-release || fail release
for hz in 750000000 "$gpu_hz"; do
	opp=/proc/device-tree/soc@0/gpu@5000000/opp-table/opp-$hz
	[ -d "$opp" ] || fail "opp-dt-absent:$hz"
	level=416
	[ "$hz" = 750000000 ] && level=$gpu_intermediate_level
	[ "$hz" = "$gpu_hz" ] && level=$gpu_level
	python3 - "$opp" "$hz" "$level" <<'PY'
import pathlib
import struct
import sys

opp = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
expected_level = int(sys.argv[3])
hz = struct.unpack(">Q", opp.joinpath("opp-hz").read_bytes())[0]
level = struct.unpack(">I", opp.joinpath("opp-level").read_bytes())[0]
bw = struct.unpack(">I", opp.joinpath("opp-peak-kBps").read_bytes())[0]
if (hz, level, bw) != (expected, expected_level, 7_216_000):
    raise SystemExit(f"opp-contract:{hz}:{level}:{bw}")
PY
done
for item in 257000000:64 342000000:128 414000000:192 520000000:256 \
	596000000:320 675000000:384 710000000:416; do
	hz=${item%%:*}
	expected=${item#*:}
	case "$hz" in
		257000000) case ",$curve_spec," in *,257000000:16,*) expected=16 ;; *,257000000:48,*) expected=48 ;; esac ;;
		342000000) case ",$curve_spec," in *,342000000:48,*) expected=48 ;; *,342000000:64,*) expected=64 ;; esac ;;
		414000000) case ",$curve_spec," in *,414000000:64,*) expected=64 ;; *,414000000:128,*) expected=128 ;; esac ;;
		520000000) case ",$curve_spec," in *,520000000:128,*) expected=128 ;; *,520000000:192,*) expected=192 ;; esac ;;
		596000000) case ",$curve_spec," in *,596000000:192,*) expected=192 ;; *,596000000:256,*) expected=256 ;; esac ;;
		675000000) case ",$curve_spec," in *,675000000:256,*) expected=256 ;; *,675000000:320,*) expected=320 ;; esac ;;
		710000000) case ",$curve_spec," in *,710000000:320,*) expected=320 ;; *,710000000:384,*) expected=384 ;; esac ;;
	esac
	opp=/proc/device-tree/soc@0/gpu@5000000/opp-table/opp-$hz
	actual=$(python3 - "$opp/opp-level" <<'PY'
import pathlib
import struct
import sys
print(struct.unpack(">I", pathlib.Path(sys.argv[1]).read_bytes())[0])
PY
)
	[ "$actual" = "$expected" ] || fail "curve-level:$hz:$actual"
done
devfreq=/sys/class/devfreq/5000000.gpu
[ -d "$devfreq" ] || fail gpu-devfreq
grep -qw "$gpu_hz" "$devfreq/available_frequencies" || fail freq-not-registered
[ "$(cat "$devfreq/max_freq")" = "$gpu_hz" ] || fail max-freq
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
echo M1892_GPU_FREQUENCY_LIVE_PASS
REMOTE
