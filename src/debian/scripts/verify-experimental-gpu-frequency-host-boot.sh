#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base_boot=${1:-}
candidate_dir=${2:-}
fail() { echo "M1892_GPU_FREQUENCY_VERIFY_FAIL: $*" >&2; exit 1; }
[ -f "$base_boot" ] && [ -d "$candidate_dir" ] || {
	echo "usage: $0 ACCEPTED_TIMER_STOP_HOST_BOOT CANDIDATE_DIR" >&2
	exit 2
}
for command in avbtool cmp cp fdtget mktemp python3 sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
metadata=$candidate_dir/BUILD-METADATA.txt
sums=$candidate_dir/SHA256SUMS
[ -f "$metadata" ] && [ -f "$sums" ] || fail missing-metadata
value() { sed -n "s/^$1=//p" "$metadata"; }
boot_name=$(value boot_filename)
gpu_hz=$(value gpu_candidate_max_hz)
level=$(value gpu_rpmh_level)
intermediate_level=$(value gpu_intermediate_rpmh_level)
curve_spec=$(value gpu_curve_overrides)
case "$boot_name" in m1892-debian13-gpu*-l*-experimental-host-boot.img) ;; *) fail boot-name ;; esac
case "$gpu_hz" in *[!0-9]*|'') fail metadata-frequency ;; esac
[ "$gpu_hz" -gt 750000000 ] && [ "$gpu_hz" -le 900000000 ] || fail metadata-frequency-range
case "$level" in 384|416) ;; *) fail metadata-level ;; esac
case "$intermediate_level" in 320|384|416) ;; *) fail metadata-intermediate-level ;; esac
case "$curve_spec" in *[!0-9,:a-z-]*|'') fail metadata-curve ;; esac
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
    raise SystemExit("unsupported-curve-metadata")
PY
boot=$candidate_dir/$boot_name
[ -f "$boot" ] || fail missing-boot
(cd "$candidate_dir" && sha256sum -c SHA256SUMS) >/dev/null || fail sidecar-hash
[ "$(stat -c %s "$boot")" = 67108864 ] || fail boot-size
[ "$(sha256sum "$base_boot" | awk '{print $1}')" = \
	3f1bddaa1a693cbcee3d09793defbddfa162a080d9b29c3af90c61947a64b19c ] || fail base-hash
cmp -s "$base_boot" "$boot" && fail candidate-equals-base

work=$(mktemp -d /tmp/m1892-gpu-frequency-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
cp "$boot" "$work/boot.img"
avbtool verify_image --image "$work/boot.img" >/dev/null || fail avb

python3 - "$base_boot" "$boot" "$work" <<'PY'
import pathlib
import struct
import sys


def unpack(raw: bytes, name: str):
    if raw[:8] != b"ANDROID!":
        raise SystemExit(f"{name}:magic")
    kernel_size = struct.unpack_from("<I", raw, 8)[0]
    ramdisk_size = struct.unpack_from("<I", raw, 16)[0]
    page_size = struct.unpack_from("<I", raw, 36)[0]
    kernel_offset = page_size
    ramdisk_offset = kernel_offset + ((kernel_size + page_size - 1) // page_size) * page_size
    return (
        raw[kernel_offset:kernel_offset + kernel_size],
        raw[ramdisk_offset:ramdisk_offset + ramdisk_size],
    )


def split(path: str, prefix: str, output: pathlib.Path):
    uefi, inner_raw = unpack(pathlib.Path(path).read_bytes(), f"{prefix}-outer")
    inner_kernel, initramfs = unpack(inner_raw, f"{prefix}-inner")
    matches = []
    start = 0
    while True:
        offset = inner_kernel.find(b"\xd0\x0d\xfe\xed", start)
        if offset < 0:
            break
        if offset + 8 <= len(inner_kernel):
            size = struct.unpack_from(">I", inner_kernel, offset + 4)[0]
            if offset + size == len(inner_kernel):
                matches.append(offset)
        start = offset + 1
    if len(matches) != 1:
        raise SystemExit(f"{prefix}:dtb-boundary:{matches}")
    offset = matches[0]
    output.joinpath(f"{prefix}.uefi").write_bytes(uefi)
    output.joinpath(f"{prefix}.kernel").write_bytes(inner_kernel[:offset])
    output.joinpath(f"{prefix}.dtb").write_bytes(inner_kernel[offset:])
    output.joinpath(f"{prefix}.initramfs").write_bytes(initramfs)


output = pathlib.Path(sys.argv[3])
split(sys.argv[1], "base", output)
split(sys.argv[2], "candidate", output)
PY

cmp -s "$work/base.uefi" "$work/candidate.uefi" || fail uefi-changed
cmp -s "$work/base.kernel" "$work/candidate.kernel" || fail kernel-changed
cmp -s "$work/base.initramfs" "$work/candidate.initramfs" || fail initramfs-changed
[ "$(sha256sum "$work/base.dtb" | awk '{print $1}')" = \
	fbbc6c83ad72d5a6b0e60d0ac31f29e8806ee3e667f702d9c5334d1f90eb2208 ] || fail base-dtb
cmp -s "$work/base.dtb" "$work/candidate.dtb" && fail dtb-unchanged

table=/soc@0/gpu@5000000/opp-table
[ "$(fdtget "$work/candidate.dtb" "$table/opp-750000000" opp-hz)" = '0 750000000' ] || fail opp-frequency:750000000
[ "$(fdtget "$work/candidate.dtb" "$table/opp-750000000" opp-level)" = "$intermediate_level" ] || fail opp-level:750000000
[ "$(fdtget "$work/candidate.dtb" "$table/opp-750000000" opp-peak-kBps)" = 7216000 ] || fail opp-bandwidth:750000000
[ "$(fdtget "$work/candidate.dtb" "$table/opp-$gpu_hz" opp-hz)" = "0 $gpu_hz" ] || fail "opp-frequency:$gpu_hz"
[ "$(fdtget "$work/candidate.dtb" "$table/opp-$gpu_hz" opp-level)" = "$level" ] || fail "opp-level:$gpu_hz"
[ "$(fdtget "$work/candidate.dtb" "$table/opp-$gpu_hz" opp-peak-kBps)" = 7216000 ] || fail "opp-bandwidth:$gpu_hz"
[ "$(fdtget "$work/candidate.dtb" "$table/opp-710000000" opp-hz)" = '0 710000000' ] || fail stock-opp710-missing
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
	[ "$(fdtget "$work/candidate.dtb" "$table/opp-$hz" opp-level)" = "$expected" ] || fail "curve-level:$hz"
done

grep -Fxq 'stage=experimental-gpu-frequency-host-boot' "$metadata" || fail metadata-stage
grep -Fxq 'gpu_accepted_intermediate_hz=750000000' "$metadata" || fail metadata-intermediate
grep -Fxq "gpu_intermediate_rpmh_level=$intermediate_level" "$metadata" || fail metadata-intermediate-level-roundtrip
grep -Fxq "gpu_curve_overrides=$curve_spec" "$metadata" || fail metadata-curve-roundtrip
if [ "$curve_spec" != none ]; then
	grep -Fxq 'candidate_test_axis=stock-opp-curve-after-top-baseline' "$metadata" || fail metadata-test-axis
elif [ "$level" = 416 ]; then
	grep -Fxq 'candidate_test_axis=frequency-only' "$metadata" || fail metadata-test-axis
else
	grep -Fxq 'candidate_test_axis=top-opp-level-after-frequency-baseline' "$metadata" || fail metadata-test-axis
fi
grep -Fxq 'default_release_candidate=no' "$metadata" || fail metadata-release-boundary
grep -Fxq 'userdata_modified=no' "$metadata" || fail metadata-userdata
grep -Fxq 'recovery_modified=no' "$metadata" || fail metadata-recovery
echo M1892_GPU_FREQUENCY_VERIFY_PASS
