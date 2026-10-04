#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base_boot=${1:-}
kernel_build=${2:-}
output_dir=${3:-}
fail() { echo "M1892_DEBIAN_HOST_BOOT_BUILD_FAIL: $*" >&2; exit 1; }
[ -f "$base_boot" ] && [ -d "$kernel_build" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 ACCEPTED_DEVELOPMENT_BOOT VERIFIED_KERNEL_BUILD NEW_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output_dir" ] || fail output-exists
for command in avbtool cmp cpio fdtget gzip mkbootimg mktemp python3 sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
base_sha=ada4df18512902c1405bd54ae8ede1223be952508505b9ee8fb3b1c5064d3b7c
base_uefi_sha=1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b
base_initramfs_sha=e7cae7d1ae3f3e953ffd7980ad44a68828aa2a5dcaeb757e613373e4be3122e1
base_inner_kernel_sha=7f1d5c9fff9906058eba743e73d35ad81e519f6969f9e1c31a7ced01a55aa182
partition_size=67108864
avb_salt=fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a
[ "$(sha256sum "$base_boot" | awk '{print $1}')" = "$base_sha" ] || fail base-hash
[ "$(stat -c %s "$base_boot")" = "$partition_size" ] || fail base-size
"$script_dir/../../public-release/scripts/verify-public-kernel.sh" "$kernel_build" >/dev/null ||
	fail kernel-contract
kernel=$kernel_build/arch/arm64/boot/Image.gz
dtb=$kernel_build/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb

work=$(mktemp -d /tmp/m1892-debian-host-boot.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$output_dir"

python3 - "$base_boot" "$work" <<'PY'
import pathlib
import struct
import sys

def unpack(raw, output, prefix):
    if raw[:8] != b"ANDROID!":
        raise SystemExit(f"{prefix}:magic")
    kernel_size, ramdisk_size = struct.unpack_from("<I4xI", raw, 8)
    page_size, header_version = struct.unpack_from("<II", raw, 36)
    kernel_offset = page_size
    ramdisk_offset = kernel_offset + ((kernel_size + page_size - 1) // page_size) * page_size
    pathlib.Path(output, f"{prefix}.kernel").write_bytes(
        raw[kernel_offset:kernel_offset + kernel_size]
    )
    pathlib.Path(output, f"{prefix}.ramdisk").write_bytes(
        raw[ramdisk_offset:ramdisk_offset + ramdisk_size]
    )
    cmdline = raw[64:576].rstrip(b"\0") + raw[608:1632].rstrip(b"\0")
    pathlib.Path(output, f"{prefix}.meta").write_text(
        f"page_size={page_size}\nheader_version={header_version}\n"
        f"kernel_size={kernel_size}\nramdisk_size={ramdisk_size}\n"
        f"cmdline={cmdline.decode('ascii')}\n",
        encoding="ascii",
    )

base, output = sys.argv[1:]
outer = pathlib.Path(base).read_bytes()
unpack(outer, output, "outer")
unpack(pathlib.Path(output, "outer.ramdisk").read_bytes(), output, "inner")
PY

[ "$(sha256sum "$work/outer.kernel" | awk '{print $1}')" = "$base_uefi_sha" ] ||
	fail base-uefi
[ "$(sha256sum "$work/inner.ramdisk" | awk '{print $1}')" = "$base_initramfs_sha" ] ||
	fail base-initramfs
[ "$(sha256sum "$work/inner.kernel" | awk '{print $1}')" = "$base_inner_kernel_sha" ] ||
	fail base-inner-kernel
grep -qx 'page_size=2048' "$work/outer.meta" || fail outer-page-size
grep -qx 'header_version=1' "$work/outer.meta" || fail outer-header-version
grep -qx 'page_size=4096' "$work/inner.meta" || fail inner-page-size
grep -qx 'header_version=0' "$work/inner.meta" || fail inner-header-version
old_cmd='earlycon=efifb console=tty0 console=ttyMSM0,115200n8 fbcon=font:TER16x32 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 rdinit=/init loglevel=4 initcall_blacklist=lmh_driver_init panic=0 m1892.usb=acm-ncm'
grep -qx "cmdline=$old_cmd" "$work/inner.meta" || fail base-cmdline
new_cmd=${old_cmd%acm-ncm}off

cat "$kernel" "$dtb" >"$work/Image.gz-dtb"
mkbootimg --header_version 0 --kernel "$work/Image.gz-dtb" \
	--ramdisk "$work/inner.ramdisk" --cmdline "$new_cmd" \
	--base 0x00000000 --kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
	--tags_offset 0x00000100 --pagesize 4096 --os_version 8.1.0 \
	--os_patch_level 2021-06-01 --output "$work/inner.img"
boot=$output_dir/m1892-debian13-stage7-host-boot-local.img
mkbootimg --header_version 1 --kernel "$work/outer.kernel" --ramdisk "$work/inner.img" \
	--base 0x00000000 --kernel_offset 0x10000000 \
	--ramdisk_offset 0x10000000 --second_offset 0x00000000 \
	--tags_offset 0x10000000 --pagesize 2048 --os_version 9.0.0 \
	--os_patch_level 2020-09-01 --output "$boot"
avbtool add_hash_footer --image "$boot" --partition_size "$partition_size" \
	--partition_name boot --salt "$avb_salt"
[ "$(stat -c %s "$boot")" = "$partition_size" ] || fail output-size

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=7-persistent-host-boot
source_boot_sha256=$base_sha
uefi_sha256=$base_uefi_sha
initramfs_sha256=$base_initramfs_sha
kernel_sha256=$(sha256sum "$kernel" | awk '{print $1}')
dtb_sha256=$(sha256sum "$dtb" | awk '{print $1}')
usb_mode=off
dwc3_dr_mode=host
typec_policy=pmi8998-tcpm-dual-power-host-data-5v500ma
uinput=builtin
root_mode=persistent-userdata
persistent_uuid=de131892-0000-4000-8000-000000000007
partition_name=boot
partition_size=$partition_size
avb_algorithm=NONE
avb_salt=$avb_salt
userdata_modified=no
recovery_modified=no
device_operation_performed=no
EOF
(cd "$output_dir" && sha256sum "$(basename "$boot")" BUILD-METADATA.txt >SHA256SUMS)
printf 'boot=%s\n' "$boot"
printf 'boot_sha256=%s\n' "$(sha256sum "$boot" | awk '{print $1}')"
echo M1892_DEBIAN_HOST_BOOT_BUILD_PASS
echo 'No device operation was performed.'
