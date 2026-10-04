#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base_boot=${1:-}
output_dir=${2:-}
fail() { echo "M1892_GPU750_BOOT_FAIL: $*" >&2; exit 1; }
[ -f "$base_boot" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 ACCEPTED_TIMER_STOP_HOST_BOOT NEW_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output_dir" ] || fail output-exists
for command in avbtool cp dtc fdtoverlay fdtget mkbootimg mktemp \
	python3 sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
overlay=$script_dir/../experiments/gpu-overclock/sdm845-meizu-m1892-gpu750.dtso
[ -f "$overlay" ] || fail missing-overlay
base_sha=3f1bddaa1a693cbcee3d09793defbddfa162a080d9b29c3af90c61947a64b19c
uefi_sha=1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b
initramfs_sha=e7cae7d1ae3f3e953ffd7980ad44a68828aa2a5dcaeb757e613373e4be3122e1
kernel_sha=f89ef26c6fa272284f6d74343627f5e11cdec8d4561573574b97f38b6118e31b
accepted_dtb_sha=fbbc6c83ad72d5a6b0e60d0ac31f29e8806ee3e667f702d9c5334d1f90eb2208
partition_size=67108864
avb_salt=fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a
[ "$(sha256sum "$base_boot" | awk '{print $1}')" = "$base_sha" ] || fail base-hash
[ "$(stat -c %s "$base_boot")" = "$partition_size" ] || fail base-size

work=$(mktemp -d /tmp/m1892-gpu750-boot.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$output_dir"

python3 - "$base_boot" "$work" <<'PY'
import hashlib
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
    kernel = raw[kernel_offset:kernel_offset + kernel_size]
    ramdisk = raw[ramdisk_offset:ramdisk_offset + ramdisk_size]
    cmdline = raw[64:576].rstrip(b"\0") + raw[608:1632].rstrip(b"\0")
    return kernel, ramdisk, page_size, cmdline


base = pathlib.Path(sys.argv[1]).read_bytes()
work = pathlib.Path(sys.argv[2])
uefi, inner_raw, outer_page, _ = unpack(base, "outer")
inner_kernel, initramfs, inner_page, cmdline = unpack(inner_raw, "inner")

matches = []
start = 0
while True:
    offset = inner_kernel.find(b"\xd0\x0d\xfe\xed", start)
    if offset < 0:
        break
    if offset + 8 <= len(inner_kernel):
        size = struct.unpack_from(">I", inner_kernel, offset + 4)[0]
        if offset + size == len(inner_kernel):
            matches.append((offset, size))
    start = offset + 1
if len(matches) != 1:
    raise SystemExit(f"inner-dtb-boundary:{matches}")
offset, _ = matches[0]
work.joinpath("uefi.bin").write_bytes(uefi)
work.joinpath("kernel-image.gz").write_bytes(inner_kernel[:offset])
work.joinpath("accepted.dtb").write_bytes(inner_kernel[offset:])
work.joinpath("initramfs.img").write_bytes(initramfs)
work.joinpath("cmdline").write_bytes(cmdline + b"\n")
work.joinpath("layout.env").write_text(
    f"outer_page={outer_page}\ninner_page={inner_page}\n", encoding="ascii"
)
PY

[ "$(sha256sum "$work/uefi.bin" | awk '{print $1}')" = "$uefi_sha" ] || fail uefi-hash
[ "$(sha256sum "$work/initramfs.img" | awk '{print $1}')" = "$initramfs_sha" ] || fail initramfs-hash
[ "$(sha256sum "$work/kernel-image.gz" | awk '{print $1}')" = "$kernel_sha" ] || fail kernel-hash
[ "$(sha256sum "$work/accepted.dtb" | awk '{print $1}')" = "$accepted_dtb_sha" ] || fail accepted-dtb-hash
grep -Fxq 'outer_page=2048' "$work/layout.env" || fail outer-page
grep -Fxq 'inner_page=4096' "$work/layout.env" || fail inner-page
grep -Fq 'm1892.usb=off' "$work/cmdline" || fail usb-mode

dtc -q -I dts -O dtb -@ -o "$work/gpu750.dtbo" "$overlay"
fdtoverlay -i "$work/accepted.dtb" -o "$work/gpu750.dtb" "$work/gpu750.dtbo"
opp=/soc@0/gpu@5000000/opp-table/opp-750000000
[ "$(fdtget "$work/gpu750.dtb" "$opp" opp-hz)" = '0 750000000' ] || fail opp-frequency
[ "$(fdtget "$work/gpu750.dtb" "$opp" opp-level)" = 416 ] || fail opp-level
[ "$(fdtget "$work/gpu750.dtb" "$opp" opp-peak-kBps)" = 7216000 ] || fail opp-bandwidth
[ "$(fdtget -t s "$work/gpu750.dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail model

cat "$work/kernel-image.gz" "$work/gpu750.dtb" >"$work/Image.gz-dtb"
cmdline=$(cat "$work/cmdline")
mkbootimg --header_version 0 --kernel "$work/Image.gz-dtb" \
	--ramdisk "$work/initramfs.img" --cmdline "$cmdline" \
	--base 0x00000000 --kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
	--tags_offset 0x00000100 --pagesize 4096 --os_version 8.1.0 \
	--os_patch_level 2021-06-01 --output "$work/inner.img"
boot=$output_dir/m1892-debian13-gpu750-experimental-host-boot.img
mkbootimg --header_version 1 --kernel "$work/uefi.bin" --ramdisk "$work/inner.img" \
	--base 0x00000000 --kernel_offset 0x10000000 \
	--ramdisk_offset 0x10000000 --second_offset 0x00000000 \
	--tags_offset 0x10000000 --pagesize 2048 --os_version 9.0.0 \
	--os_patch_level 2020-09-01 --output "$boot"
avbtool add_hash_footer --image "$boot" --partition_size "$partition_size" \
	--partition_name boot --salt "$avb_salt"
[ "$(stat -c %s "$boot")" = "$partition_size" ] || fail output-size
cp "$boot" "$work/boot.img"
avbtool verify_image --image "$work/boot.img" >/dev/null || fail avb

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=experimental-gpu750-host-boot
device=meizu-m1892
source_boot_sha256=$base_sha
rollback_boot_sha256=$base_sha
uefi_sha256=$uefi_sha
initramfs_sha256=$initramfs_sha
kernel_sha256=$kernel_sha
accepted_dtb_sha256=$accepted_dtb_sha
experimental_dtb_sha256=$(sha256sum "$work/gpu750.dtb" | awk '{print $1}')
overlay_sha256=$(sha256sum "$overlay" | awk '{print $1}')
gpu_stock_max_hz=710000000
gpu_candidate_max_hz=750000000
gpu_rpmh_level=416
usb_mode=off
userdata_modified=no
recovery_modified=no
default_release_candidate=no
device_operation_performed=no
EOF
(cd "$output_dir" && sha256sum "$(basename "$boot")" BUILD-METADATA.txt >SHA256SUMS)
echo "boot=$boot"
echo "boot_sha256=$(sha256sum "$boot" | awk '{print $1}')"
echo M1892_GPU750_BOOT_PASS
echo 'No device operation was performed.'
