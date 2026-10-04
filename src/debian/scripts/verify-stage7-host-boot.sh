#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base_boot=${1:-}
kernel_build=${2:-}
candidate_dir=${3:-}
fail() { echo "M1892_DEBIAN_HOST_BOOT_VERIFY_FAIL: $*" >&2; exit 1; }
[ -f "$base_boot" ] && [ -d "$kernel_build" ] && [ -d "$candidate_dir" ] || {
	echo "usage: $0 ACCEPTED_DEVELOPMENT_BOOT VERIFIED_KERNEL_BUILD CANDIDATE_DIR" >&2
	exit 2
}
for command in avbtool cmp cpio fdtget find gzip python3 sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
base_sha=ada4df18512902c1405bd54ae8ede1223be952508505b9ee8fb3b1c5064d3b7c
base_uefi_sha=1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b
base_initramfs_sha=e7cae7d1ae3f3e953ffd7980ad44a68828aa2a5dcaeb757e613373e4be3122e1
partition_size=67108864
boot=$candidate_dir/m1892-debian13-stage7-host-boot-local.img
metadata=$candidate_dir/BUILD-METADATA.txt
[ "$(sha256sum "$base_boot" | awk '{print $1}')" = "$base_sha" ] || fail base-hash
[ -f "$boot" ] && [ -f "$metadata" ] && [ -f "$candidate_dir/SHA256SUMS" ] ||
	fail candidate-files
(cd "$candidate_dir" && sha256sum -c SHA256SUMS >/dev/null) || fail sidecars
[ "$(stat -c %s "$boot")" = "$partition_size" ] || fail boot-size
"$script_dir/../../public-release/scripts/verify-public-kernel.sh" "$kernel_build" >/dev/null ||
	fail kernel-contract
kernel=$kernel_build/arch/arm64/boot/Image.gz
dtb=$kernel_build/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb
grep -Fxq 'stage=7-persistent-host-boot' "$metadata" || fail metadata-stage
grep -Fxq 'usb_mode=off' "$metadata" || fail metadata-usb
grep -Fxq 'dwc3_dr_mode=host' "$metadata" || fail metadata-dwc3
grep -Fxq 'uinput=builtin' "$metadata" || fail metadata-uinput
grep -Fxq 'userdata_modified=no' "$metadata" || fail metadata-userdata
grep -Fxq 'recovery_modified=no' "$metadata" || fail metadata-recovery

work=$(mktemp -d /tmp/m1892-debian-host-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
cp "$boot" "$work/boot.img"
avbtool verify_image --image "$work/boot.img" >/dev/null || fail avb
avbtool info_image --image "$work/boot.img" >"$work/avb.txt" || fail avb-info
grep -q '^Algorithm:[[:space:]]*NONE$' "$work/avb.txt" || fail avb-algorithm
grep -q '^      Partition Name:[[:space:]]*boot$' "$work/avb.txt" || fail avb-partition

python3 - "$boot" "$base_boot" "$work" <<'PY'
import pathlib
import struct
import sys

def unpack(path, output, prefix):
    raw = pathlib.Path(path).read_bytes()
    if raw[:8] != b"ANDROID!":
        raise SystemExit(f"{prefix}:magic")
    kernel_size, ramdisk_size = struct.unpack_from("<I4xI", raw, 8)
    page_size, header_version = struct.unpack_from("<II", raw, 36)
    ko = page_size
    ro = ko + ((kernel_size + page_size - 1) // page_size) * page_size
    pathlib.Path(output, f"{prefix}.kernel").write_bytes(raw[ko:ko + kernel_size])
    pathlib.Path(output, f"{prefix}.ramdisk").write_bytes(raw[ro:ro + ramdisk_size])
    cmdline = raw[64:576].rstrip(b"\0") + raw[608:1632].rstrip(b"\0")
    pathlib.Path(output, f"{prefix}.meta").write_text(
        f"page_size={page_size}\nheader_version={header_version}\n"
        f"cmdline={cmdline.decode('ascii')}\n",
        encoding="ascii",
    )

candidate, base, output = sys.argv[1:]
unpack(candidate, output, "new-outer")
unpack(pathlib.Path(output, "new-outer.ramdisk"), output, "new-inner")
unpack(base, output, "old-outer")
unpack(pathlib.Path(output, "old-outer.ramdisk"), output, "old-inner")
PY

[ "$(sha256sum "$work/new-outer.kernel" | awk '{print $1}')" = "$base_uefi_sha" ] ||
	fail uefi-hash
[ "$(sha256sum "$work/new-inner.ramdisk" | awk '{print $1}')" = "$base_initramfs_sha" ] ||
	fail initramfs-hash
cmp -s "$work/new-outer.kernel" "$work/old-outer.kernel" || fail uefi-changed
cmp -s "$work/new-inner.ramdisk" "$work/old-inner.ramdisk" || fail initramfs-changed
grep -qx 'page_size=2048' "$work/new-outer.meta" || fail outer-page-size
grep -qx 'header_version=1' "$work/new-outer.meta" || fail outer-header
grep -qx 'page_size=4096' "$work/new-inner.meta" || fail inner-page-size
grep -qx 'header_version=0' "$work/new-inner.meta" || fail inner-header
expected_cmd='earlycon=efifb console=tty0 console=ttyMSM0,115200n8 fbcon=font:TER16x32 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 rdinit=/init loglevel=4 initcall_blacklist=lmh_driver_init panic=0 m1892.usb=off'
grep -qx "cmdline=$expected_cmd" "$work/new-inner.meta" || fail cmdline
cat "$kernel" "$dtb" >"$work/expected-kernel-dtb"
cmp -s "$work/new-inner.kernel" "$work/expected-kernel-dtb" || fail kernel-dtb
cmp -s "$boot" "$base_boot" && fail unchanged-from-base

[ "$(fdtget -t s "$dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail dt-model
[ "$(fdtget -t s "$dtb" /soc@0/usb@a6f8800/usb@a600000 dr_mode)" = host ] ||
	fail dt-host
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/typec@1300 status)" = okay ] ||
	fail dt-typec
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/usb-vbus-regulator@1100 status)" = okay ] ||
	fail dt-vbus
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/typec@1300/connector data-role)" = host ] ||
	fail dt-data-role
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/typec@1300/connector power-role)" = dual ] ||
	fail dt-power-role
[ "$(fdtget "$dtb" /soc@0/spmi@c440000/pmic@2/typec@1300/connector op-sink-microwatt)" = 2500000 ] ||
	fail dt-sink-power
for option in CONFIG_INPUT_JOYDEV CONFIG_INPUT_JOYSTICK CONFIG_JOYSTICK_XPAD \
	CONFIG_INPUT_UINPUT; do
	grep -qx "$option=y" "$kernel_build/.config" || fail "config:${option#CONFIG_}"
done
gzip -t "$work/new-inner.ramdisk" || fail initramfs-gzip
mkdir "$work/initramfs"
(cd "$work/initramfs" && gzip -dc ../new-inner.ramdisk | cpio -id --quiet) ||
	fail initramfs-extract
grep -Fxq 'root_mode=persistent-userdata' "$work/initramfs/init" || fail root-mode
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' \
	"$work/initramfs/init" || fail root-uuid
printf 'boot_sha256=%s\n' "$(sha256sum "$boot" | awk '{print $1}')"
echo M1892_DEBIAN_HOST_BOOT_VERIFY_PASS
