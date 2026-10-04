#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_recovery=${1:-}
rootfs=${2:-}
output_dir=${3:-}
panel_module=${M1892_PANEL_MODULE:-}
kernel_image_gz=${M1892_KERNEL_IMAGE_GZ:-}
kernel_dtb=${M1892_KERNEL_DTB:-}
kernel_manifest=${M1892_KERNEL_MANIFEST:-}
kernel_dtb_metadata=${M1892_KERNEL_DTB_METADATA:-}
stage=${M1892_DEBIAN_STAGE:-2}
root_mode=${M1892_DEBIAN_ROOT_MODE:-ram-loopback}
persistent_uuid=disabled
persistent_label=disabled
rootfs_mode=ram-loopback
case "$stage" in
	2) stage_label=systemd-ram-root ;;
	3) stage_label=plasma-mobile-ram-root ;;
	*) echo 'M1892_DEBIAN_RECOVERY_FAIL: invalid-stage' >&2; exit 2 ;;
esac
case "$root_mode" in
	ram-loopback) ;;
	persistent-userdata)
		[ "$stage" = 3 ] || { echo 'M1892_DEBIAN_RECOVERY_FAIL: persistent-stage' >&2; exit 2; }
		persistent_uuid=de131892-0000-4000-8000-000000000007
		persistent_label=M1892_DEB13
		rootfs_mode=persistent-userdata-image
		;;
	*) echo 'M1892_DEBIAN_RECOVERY_FAIL: invalid-root-mode' >&2; exit 2 ;;
esac
[ -f "$source_recovery" ] && [ -f "$rootfs" ] && [ -f "$panel_module" ] && \
	[ -n "$output_dir" ] || {
	echo "usage: M1892_PANEL_MODULE=... $0 R545_RECOVERY STAGE2_ROOTFS_EXT4_GZ ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "${kernel_image_gz:+image}:${kernel_dtb:+dtb}:${kernel_manifest:+manifest}" in
	::) ;;
	image:dtb:manifest) ;;
	*) echo 'M1892_DEBIAN_RECOVERY_FAIL: incomplete-public-kernel-inputs' >&2; exit 2 ;;
esac
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_STAGE2_RECOVERY_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ ! -e "$output_dir" ] || { echo 'M1892_DEBIAN_STAGE2_RECOVERY_FAIL: output-exists' >&2; exit 1; }

source_recovery_sha=e7db2b91ffe1c82f4ac4b61ed56a2271f050e3461c235d17de3831f96f855b9d
source_uefi_sha=1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b
source_kernel_dtb_sha=b9b95bc1df5681cb492f131e91dadada666e6bf8e7eb1d9561baaf8caf91d424
source_initramfs_sha=668394808d14f1d81ddc833329d45e4592a49e7bbe39aaf0225f20f3d5851465
source_cmdline_sha=730566b9d497693028a8ba5cf370ca4a42f036b03fc203bfe857bb3aa91886c7
source_panel_module_sha=be7fd48b47e58d63f534aa968665477932d86559cd0122dbbd99b52a55717fe1
stock_tail_offset=26091520
partition_size=67108864

fail() { echo "M1892_DEBIAN_STAGE2_RECOVERY_FAIL: $*" >&2; exit 1; }
require_sha() { [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ] || fail "hash:$1"; }
for command in cat cmp cpio dd fdtget find gzip install mkbootimg mktemp python3 \
	sed sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
require_sha "$source_recovery" "$source_recovery_sha"
panel_module_sha=$source_panel_module_sha
if [ -n "$kernel_image_gz" ]; then
	[ -f "$kernel_manifest" ] || fail public-kernel-manifest-absent
	panel_module_sha=$(sed -n 's/^panel_sha256=//p' "$kernel_manifest")
	[ "${#panel_module_sha}" -eq 64 ] || fail public-panel-manifest-hash
fi
require_sha "$panel_module" "$panel_module_sha"
[ "$(stat -c %s "$source_recovery")" = "$partition_size" ] || fail source-size
[ -f "$rootfs.sha256" ] || fail rootfs-sidecar-absent
(cd "$(dirname -- "$rootfs")" && sha256sum -c "$(basename -- "$rootfs").sha256") >/dev/null || fail rootfs-hash

work=$(mktemp -d /tmp/m1892-debian-stage2-recovery.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/initramfs" "$output_dir"
python3 - "$source_recovery" "$work" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if raw[:8] != b'ANDROID!': raise SystemExit('outer-magic')
oks, ors, ops = (struct.unpack_from('<I', raw, off)[0] for off in (8, 16, 36))
oro = ops + ((oks + ops - 1) // ops) * ops
inner = raw[oro:oro + ors]
if inner[:8] != b'ANDROID!': raise SystemExit('inner-magic')
iks, irs, ips = (struct.unpack_from('<I', inner, off)[0] for off in (8, 16, 36))
iro = ips + ((iks + ips - 1) // ips) * ips
cmd = inner[64:576].split(b'\0', 1)[0] + inner[608:1632].split(b'\0', 1)[0]
parts = {
    'uefi': raw[ops:ops + oks],
    'kernel-dtb': inner[ips:ips + iks],
    'initramfs.cpio.gz': inner[iro:iro + irs],
    'cmdline': cmd,
}
for name, data in parts.items():
    open(sys.argv[2] + '/' + name, 'wb').write(data)
PY
require_sha "$work/uefi" "$source_uefi_sha"
require_sha "$work/initramfs.cpio.gz" "$source_initramfs_sha"
require_sha "$work/cmdline" "$source_cmdline_sha"
kernel_mode=source-r545
kernel_image_sha=none
kernel_dtb_sha=none
kernel_dtb_mode=source-r545
kernel_dtb_metadata_sha=none
if [ -n "$kernel_image_gz" ]; then
	[ -f "$kernel_image_gz" ] && [ -f "$kernel_dtb" ] && [ -f "$kernel_manifest" ] ||
		fail public-kernel-input-absent
	[ "$(sed -n 's/^kernel_sha256=//p' "$kernel_manifest")" = \
		"$(sha256sum "$kernel_image_gz" | awk '{print $1}')" ] || fail public-kernel-hash
	public_dtb_sha=$(sed -n 's/^dtb_sha256=//p' "$kernel_manifest")
	actual_dtb_sha=$(sha256sum "$kernel_dtb" | awk '{print $1}')
	if [ -n "$kernel_dtb_metadata" ]; then
		[ -f "$kernel_dtb_metadata" ] || fail public-dev-dtb-metadata-absent
		grep -Fxq "base_dtb_sha256=$public_dtb_sha" "$kernel_dtb_metadata" &&
			grep -Fxq "output_dtb_sha256=$actual_dtb_sha" "$kernel_dtb_metadata" &&
			grep -Fxq 'dev_usb_overlay_sha256=4b951474f531cb9c6b59c3b779e3b36da2bc3baf4f20de6457e15b3f6c38a64c' \
				"$kernel_dtb_metadata" &&
			grep -Fxq 'dwc3_dr_mode=peripheral' "$kernel_dtb_metadata" ||
			fail public-dev-dtb-metadata
		kernel_dtb_mode=recovery-dev-usb
		kernel_dtb_metadata_sha=$(sha256sum "$kernel_dtb_metadata" | awk '{print $1}')
	else
		[ "$public_dtb_sha" = "$actual_dtb_sha" ] || fail public-dtb-hash
		kernel_dtb_mode=public-product
	fi
	grep -Fxq 'upstream_commit=85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8' \
		"$kernel_manifest" || fail public-kernel-commit
	grep -Fxq 'compiler=aarch64-linux-gnu-gcc-11.4.0' "$kernel_manifest" ||
		fail public-kernel-compiler
	gzip -t "$kernel_image_gz" || fail public-kernel-gzip
	case $(fdtget "$kernel_dtb" / compatible 2>/dev/null) in
		*meizu,m1892*) ;;
		*) fail public-dtb-compatible ;;
	esac
	cat "$kernel_image_gz" "$kernel_dtb" >"$work/kernel-dtb"
	kernel_mode=public-clean
	kernel_image_sha=$(sha256sum "$kernel_image_gz" | awk '{print $1}')
	kernel_dtb_sha=$(sha256sum "$kernel_dtb" | awk '{print $1}')
else
	require_sha "$work/kernel-dtb" "$source_kernel_dtb_sha"
fi
case $(cat "$work/cmdline") in *'m1892.usb=acm-ncm'*) ;; *) fail usb-cmdline ;; esac

gzip -dc "$work/initramfs.cpio.gz" >"$work/source-initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/source-initramfs.cpio")
for required in bin/busybox bin/m1892-display-auto-r59 bin/reboot-fastboot; do
	[ -e "$work/initramfs/$required" ] || fail "source-initramfs-missing:$required"
done
provider_mode=source-r545-external-haptics
if [ "$kernel_mode" = public-clean ]; then
	sed -i '/^haptic_modules=\/lib\/modules\/m1892-haptics$/,/bdbf21e787b91533c4af53d7f7189d9207d7fe8b82931f015f2670f1f5a4a22f || exit 43$/d' \
		"$work/initramfs/bin/m1892-display-auto-r59"
	grep -Fq 'cat "$haptic/safety"' "$work/initramfs/bin/m1892-display-auto-r59" ||
		fail public-provider-haptic-safety-gate
	if grep -Fq 'haptic_modules=' "$work/initramfs/bin/m1892-display-auto-r59"; then
		fail public-provider-external-haptic-remains
	fi
	provider_mode=public-built-in-haptics
fi
install -D -m 0644 "$panel_module" \
	"$work/initramfs/lib/modules/m1892-panel/panel-samsung-sofef00m.ko"
bytes=$(stat -c %s "$rootfs")
sha=$(sha256sum "$rootfs" | awk '{print $1}')
rootfs_metadata=$(dirname -- "$rootfs")/BUILD-METADATA.txt
[ -r "$rootfs_metadata" ] || fail rootfs-metadata-absent
[ "$(sed -n 's/^root_mode=//p' "$rootfs_metadata")" = "$rootfs_mode" ] ||
	fail rootfs-root-mode-mismatch
image_bytes=$(sed -n 's/^persistent_root_image_size=//p' "$rootfs_metadata")
image_sha=$(sed -n 's/^persistent_root_image_sha256=//p' "$rootfs_metadata")
case "$image_bytes" in ''|*[!0-9]*) fail invalid-rootfs-image-size ;; esac
case "$image_sha" in ????????*) ;; *) fail invalid-rootfs-image-hash ;; esac
[ "${#image_sha}" -eq 64 ] || fail invalid-rootfs-image-hash
init_template=$tree_dir/initramfs/init-stage2.in
if [ "$stage" = 3 ]; then
	sed -e 's/stage2/stage3/g' -e 's/STAGE2/STAGE3/g' \
		-e 's/mode=0755,nodev,nosuid tmpfs \/run/mode=0755,nodev,nosuid,size=6144m tmpfs \/run/' \
		"$init_template" >"$work/init-template"
	init_template=$work/init-template
fi
sed -e "s/@ROOTFS_BYTES@/$bytes/" -e "s/@ROOTFS_SHA256@/$sha/" \
	-e "s/@ROOTFS_IMAGE_BYTES@/$image_bytes/" \
	-e "s/@ROOTFS_IMAGE_SHA256@/$image_sha/" \
	-e "s/@PANEL_MODULE_SHA256@/$panel_module_sha/" \
	-e "s/@ROOT_MODE@/$root_mode/" \
	-e "s/@PERSISTENT_UUID@/$persistent_uuid/" \
	-e "s/@PERSISTENT_LABEL@/$persistent_label/" \
	"$init_template" >"$work/init"
grep -q '@[A-Z_]*@' "$work/init" && fail unresolved-init-template
install -m 0755 "$work/init" "$work/initramfs/init"
find "$work/initramfs" -xdev -exec touch -h -d '@1788739200' {} +
(cd "$work/initramfs" && find . -print0 >"$work/initramfs-files.unsorted0")
LC_ALL=C sort -z "$work/initramfs-files.unsorted0" >"$work/initramfs-files.list0"
(cd "$work/initramfs" && cpio --null -o -H newc --owner=0:0 \
	--reproducible --quiet <"$work/initramfs-files.list0" \
	>"$work/stage2-initramfs.cpio")
gzip -n -9 <"$work/stage2-initramfs.cpio" >"$work/stage2-initramfs.cpio.gz"

mkbootimg --header_version 0 --kernel "$work/kernel-dtb" \
	--ramdisk "$work/stage2-initramfs.cpio.gz" --cmdline "$(cat "$work/cmdline")" \
	--base 0 --kernel_offset 0x8000 --ramdisk_offset 0x01000000 \
	--second_offset 0x00f00000 --tags_offset 0x100 --pagesize 4096 \
	--os_version 8.1.0 --os_patch_level 2021-06-01 --output "$work/inner"
mkbootimg --header_version 1 --kernel "$work/uefi" --ramdisk "$work/inner" \
	--base 0 --kernel_offset 0x10000000 --ramdisk_offset 0x10000000 \
	--second_offset 0 --tags_offset 0x10000000 --pagesize 2048 \
	--os_version 9.0.0 --os_patch_level 2020-09-01 --output "$work/payload"
[ "$(stat -c %s "$work/payload")" -lt "$stock_tail_offset" ] || fail tail-overlap

dd if="$source_recovery" of="$work/source-tail" bs=1M iflag=skip_bytes \
	skip="$stock_tail_offset" status=none
if [ "$root_mode" = persistent-userdata ]; then
	output=$output_dir/m1892-debian13-stage7-persistent-recovery-local.img
else
	output=$output_dir/m1892-debian13-stage${stage}-ram-recovery-local.img
fi
cp "$source_recovery" "$output.tmp"
dd if=/dev/zero of="$output.tmp" bs=1M iflag=count_bytes count="$stock_tail_offset" \
	conv=notrunc status=none
dd if="$work/payload" of="$output.tmp" conv=notrunc status=none
dd if="$output.tmp" of="$work/output-tail" bs=1M iflag=skip_bytes \
	skip="$stock_tail_offset" status=none
cmp -s "$work/source-tail" "$work/output-tail" || fail stock-tail-changed
mv "$output.tmp" "$output"
[ "$(stat -c %s "$output")" = "$partition_size" ] || fail output-size

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=$stage-$stage_label
source_recovery_sha256=$source_recovery_sha
source_uefi_sha256=$source_uefi_sha
source_kernel_dtb_sha256=$source_kernel_dtb_sha
kernel_mode=$kernel_mode
kernel_image_sha256=$kernel_image_sha
kernel_dtb_sha256=$kernel_dtb_sha
kernel_dtb_mode=$kernel_dtb_mode
kernel_dtb_metadata_sha256=$kernel_dtb_metadata_sha
provider_mode=$provider_mode
source_initramfs_sha256=$source_initramfs_sha
panel_module_sha256=$panel_module_sha
stage2_initramfs_sha256=$(sha256sum "$work/stage2-initramfs.cpio.gz" | awk '{print $1}')
rootfs_sha256=$sha
rootfs_size=$bytes
rootfs_image_sha256=$image_sha
rootfs_image_size=$image_bytes
root_mode=$root_mode
persistent_uuid=$persistent_uuid
persistent_label=$persistent_label
development_usb=acm-ncm
stock_tail_changed=no
persistent_boot_modified=no
userdata_modified=no
distribution=owner-local-development-only
EOF
(cd "$output_dir" && sha256sum "$(basename "$output")" BUILD-METADATA.txt >SHA256SUMS)
echo "recovery=$output"
echo "recovery_sha256=$(sha256sum "$output" | awk '{print $1}')"
echo "M1892_DEBIAN_STAGE${stage}_RECOVERY_BUILD_PASS"
echo 'No device operation was performed.'
