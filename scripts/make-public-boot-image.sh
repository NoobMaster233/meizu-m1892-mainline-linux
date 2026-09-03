#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

kernel=${1:-}
dtb=${2:-}
uefi_kernel=${3:-}
uefi_manifest=${4:-}
rootfs=${5:-}
output=${6:-}
fail() { echo "M1892_PUBLIC_BOOT_FAIL: $*" >&2; exit 1; }
[ -f "$kernel" ] || fail missing-kernel
[ -f "$dtb" ] || fail missing-dtb
[ -f "$uefi_kernel" ] || fail missing-uefi-kernel
[ -f "$uefi_manifest" ] || fail missing-uefi-manifest
[ -f "$rootfs" ] || fail missing-rootfs
[ -n "$output" ] || fail missing-output
[ ! -e "$output" ] || fail output-exists
for command in aarch64-linux-gnu-gcc avbtool awk cpio debugfs fdtget find gzip \
	install ln mkbootimg mkdir readlink sha256sum sort stat touch; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

require_sha()
{
	actual=$(sha256sum "$1" | awk '{print $1}')
	[ "$actual" = "$2" ] || fail "hash:$1:$actual"
}
# Both hashes below are from two independent clean builds of the frozen K1
# source set.  The source-composed product DTB contains no fixed Bluetooth
# identity.  Physical acceptance remains a separate recovery-first gate; this
# maker authenticates inputs and must not itself be treated as that evidence.
require_sha "$kernel" 4e1fbf09d05f342da25e9cfcb29ea6fc973c05f31cec3992819455895423856c
require_sha "$dtb" 4e09e9aaac03503bd9c76afa7c1b602bad43227b6d96bd15f7abef5ac02244f4
manifest_value()
{
	key=$1
	awk -F= -v key="$key" '$1==key { if (++count > 1) exit 2; value=$2 }
		END { if (count != 1) exit 1; print value }' "$uefi_manifest" ||
		fail "uefi-manifest:$key"
}
[ "$(manifest_value format)" = m1892-public-edk2-loader-v1 ] || fail uefi-manifest-format
[ "$(manifest_value edk2_sdm845_commit)" = e1952621f419f8db60ed28271264e1b5184c571d ] ||
	fail uefi-manifest-edk2-commit
[ "$(manifest_value edk2_commit)" = e7aac7fc137e247edad22f7ee53b9a1fba227397 ] ||
	fail uefi-manifest-edk2-submodule-commit
[ "$(manifest_value edk2_platforms_commit)" = 982212662c71b6c734b7578526071d6b78da3bcc ] ||
	fail uefi-manifest-edk2-platforms-commit
[ "$(manifest_value simpleinit_commit)" = 29e062805776db5ab7a61d07ef040d43aed71161 ] ||
	fail uefi-manifest-simpleinit-commit
[ "$(manifest_value freetype_commit)" = 6a2b3e4007e794bfc6c91030d0ed987f925164a8 ] ||
	fail uefi-manifest-freetype-commit
[ "$(manifest_value basetools_brotli_commit)" = f4153a09f87cbb9c826d8fc12c74642bb2d879ea ] ||
	fail uefi-manifest-basetools-brotli-commit
[ "$(manifest_value static_config_sha256)" = 644d43c5ec4d93a56c2b9beab55562e75b43124ff381cf1f5d64a11e64543787 ] ||
	fail uefi-manifest-static-config
[ "$(manifest_value edk2_patch_sha256)" = 4ea1ce45ec3a8741ca8984a4e1f0e6104a904a63d32da34f9c0c3e452ff87441 ] ||
	fail uefi-manifest-edk2-patch
[ "$(manifest_value simpleinit_fdt_patch_sha256)" = 8741442511fd98840e86a588cd38b7a7ac73593d3060771fca1c6546e4737daf ] ||
	fail uefi-manifest-simpleinit-fdt-patch
[ "$(manifest_value simpleinit_hold_patch_sha256)" = 7d006b53fdac41a99bee2645afab1c84868c37f3c6224d5e834fc491b70d855f ] ||
	fail uefi-manifest-simpleinit-hold-patch
require_sha "$uefi_kernel" "$(manifest_value uefi_loader_sha256)"
[ "$(stat -c %s "$rootfs")" = 8589934592 ] || fail rootfs-size
[ "$(fdtget -t s "$dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail dt-model
bluetooth=/soc@0/geniqup@8c0000/serial@898000/bluetooth
if fdtget "$dtb" "$bluetooth" local-bd-address >/dev/null 2>&1; then
	fail fixed-bluetooth-address
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
init_source=$script_dir/../src/boot/init-r537-public-root
[ -r "$init_source" ] || fail missing-init-source
reboot_fastboot_source=$script_dir/../src/boot/reboot-fastboot.c
[ -r "$reboot_fastboot_source" ] || fail missing-reboot-fastboot-source
work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-public-boot.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/initramfs/bin" "$work/initramfs/lib"
debugfs -R "dump -p /bin/busybox $work/initramfs/bin/busybox" "$rootfs" \
	>/dev/null 2>&1 || fail rootfs-busybox
debugfs -R "dump -p /lib/ld-musl-aarch64.so.1 $work/initramfs/lib/ld-musl-aarch64.so.1" \
	"$rootfs" >/dev/null 2>&1 || fail rootfs-musl
require_sha "$work/initramfs/bin/busybox" \
	efc0abd6cb598f0555017d868ed9222f80908757eb13159e786721d321e381a8
require_sha "$work/initramfs/lib/ld-musl-aarch64.so.1" \
	32377e6d71725bb019e9ff6d5e9f16b4d5156d6f2c36504191c2d6a7c4d4a44d
# Alpine's dynamic BusyBox requests libc.musl-aarch64.so.1. The loader and
# libc are one file exposed under both names by this symlink. Without the
# alias, the kernel reaches rdinit but cannot execute BusyBox.
ln -s ld-musl-aarch64.so.1 \
	"$work/initramfs/lib/libc.musl-aarch64.so.1"
[ "$(readlink "$work/initramfs/lib/libc.musl-aarch64.so.1")" = \
	ld-musl-aarch64.so.1 ] || fail musl-libc-link
install -m 0755 "$init_source" "$work/initramfs/init"
aarch64-linux-gnu-gcc -Os -static -s -Wl,--build-id=none \
	-o "$work/initramfs/bin/reboot-fastboot" \
	"$reboot_fastboot_source"
require_sha "$work/initramfs/bin/reboot-fastboot" \
	2b8eb06dcf71544e6ae7f189c37bd9bdd67c6f18e36d0fa44fa2e35814f989ba
chmod 0755 "$work/initramfs/bin/busybox" "$work/initramfs/lib/ld-musl-aarch64.so.1"
find "$work/initramfs" -exec touch -h -d '@1785081600' {} +
(
	cd "$work/initramfs"
	find . -print0 | LC_ALL=C sort -z | \
		cpio --null -o -H newc --reproducible --owner=0:0 --quiet | \
		gzip -9n >"$work/initramfs.cpio.gz"
)
cat "$kernel" "$dtb" >"$work/Image.gz-dtb"
cmdline='earlycon=efifb console=tty0 console=ttyMSM0,115200n8 fbcon=font:TER16x32 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 rdinit=/init loglevel=4 initcall_blacklist=lmh_driver_init panic=0 m1892.usb=off'
mkbootimg --header_version 0 --kernel "$work/Image.gz-dtb" \
	--ramdisk "$work/initramfs.cpio.gz" --cmdline "$cmdline" \
	--base 0x00000000 --kernel_offset 0x00008000 \
	--ramdisk_offset 0x01000000 --second_offset 0x00f00000 \
	--tags_offset 0x00000100 --pagesize 4096 --os_version 8.1.0 \
	--os_patch_level 2021-06-01 --output "$work/inner.img"
mkbootimg --header_version 1 --kernel "$uefi_kernel" --ramdisk "$work/inner.img" \
	--base 0x00000000 --kernel_offset 0x10000000 \
	--ramdisk_offset 0x10000000 --second_offset 0x00000000 \
	--tags_offset 0x10000000 --pagesize 2048 --os_version 9.0.0 \
	--os_patch_level 2020-09-01 --output "$output"
avbtool add_hash_footer --image "$output" --partition_size 67108864 \
	--partition_name boot \
	--salt fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a
[ "$(stat -c %s "$output")" = 67108864 ] || fail output-size
printf 'boot_sha256=%s\n' "$(sha256sum "$output" | awk '{print $1}')"
printf 'initramfs_sha256=%s\n' "$(sha256sum "$work/initramfs.cpio.gz" | awk '{print $1}')"
echo M1892_PUBLIC_BOOT_PASS
