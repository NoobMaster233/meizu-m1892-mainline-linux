#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
accepted_boot=${1:-} kernel=${2:-} dtb=${3:-} base_tar=${4:-} rootfs=${5:-} output=${6:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail() { echo "M1892_INSTALLER_BOOT_FAIL: $*" >&2; exit 1; }
for input in "$accepted_boot" "$kernel" "$dtb" "$base_tar" "$rootfs"; do [ -f "$input" ] || fail input-absent; done
case "$output" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output" ] || fail output-exists
for command in mkbootimg avbtool python3 tar cpio gzip fdtget sha256sum stat awk sed cp aarch64-linux-gnu-readelf aarch64-linux-gnu-gcc; do command -v "$command" >/dev/null || fail "missing-command:$command"; done
[ "$(stat -c %s "$accepted_boot")" = 67108864 ] || fail loader-size
metadata=$(dirname "$rootfs")/BUILD-METADATA.txt
[ -f "$metadata" ] && [ -f "$base_tar.sha256" ] || fail sidecar-absent
value() { sed -n "s/^$1=//p" "$metadata"; }
[ "$(value vendor_firmware)" = absent ] && [ "$(value owner_credentials)" = absent ] || fail ram-scope
[ "$(value persistent_root_image_size)" = 536870912 ] || fail ram-image-size
for hash in "$(value artifact_sha256)" "$(value persistent_root_image_sha256)"; do
 printf '%s\n' "$hash" | grep -Eq '^[a-f0-9]{64}$' || fail metadata-hash
done
[ "$(stat -c %s "$rootfs")" = "$(value artifact_size)" ] || fail rootfs-size
(cd "$(dirname "$base_tar")" && sha256sum -c "$(basename "$base_tar").sha256") >/dev/null || fail base-hash
[ "$(sha256sum "$rootfs" | awk '{print $1}')" = "$(value artifact_sha256)" ] || fail rootfs-hash
[ "$(sha256sum "$kernel" | awk '{print $1}')" = f0bf52f03f6d83d602aa6cda9e781aff1fdc0491feb52a3199aa387099121ab7 ] || fail accepted-kernel
[ "$(sha256sum "$dtb" | awk '{print $1}')" = 3cbf9f0377d680a3ab5335dfe4ac3f761a6eab4a48bd452cfc827dc93cb54ccd ] || fail accepted-dev-dtb
[ "$(sha256sum "$accepted_boot" | awk '{print $1}')" = 3be84b46d6e90c890903d157ae9f9b0450213c2cc1f21807274c8df946b24942 ] || fail loader-source
[ "$(fdtget -t s "$dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail dt-model
work=$(mktemp -d /tmp/m1892-installer-boot.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$output" "$work/initramfs/bin"
rebooter_source=$script_dir/../../public-release/src/boot/reboot-fastboot.c
[ -f "$rebooter_source" ] || fail recovery-source
aarch64-linux-gnu-gcc -Os -static -s -Wl,--build-id=none -o "$work/initramfs/bin/reboot-fastboot" "$rebooter_source"
[ "$(sha256sum "$work/initramfs/bin/reboot-fastboot" | awk '{print $1}')" = 2b8eb06dcf71544e6ae7f189c37bd9bdd67c6f18e36d0fa44fa2e35814f989ba ] || fail accepted-recovery-binary
python3 - "$accepted_boot" "$work/uefi" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as stream:
    header = stream.read(2048)
    if header[:8] != b'ANDROID!': raise SystemExit('android-header')
    size = struct.unpack_from('<I', header, 8)[0]
    page = struct.unpack_from('<I', header, 36)[0]
    stream.seek(page)
    data = stream.read(size)
with open(sys.argv[2], 'wb') as stream: stream.write(data)
PY
[ "$(sha256sum "$work/uefi" | awk '{print $1}')" = 1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b ] || fail uefi-hash
tar -xOf "$base_tar" ./usr/bin/busybox >"$work/initramfs/bin/busybox"
chmod 0755 "$work/initramfs/bin/busybox"
aarch64-linux-gnu-readelf -h "$work/initramfs/bin/busybox" | grep -q AArch64 || fail busybox-architecture
if aarch64-linux-gnu-readelf -l "$work/initramfs/bin/busybox" | grep -q INTERP; then fail busybox-not-static; fi
sed -e "s/@ARCHIVE_BYTES@/$(stat -c %s "$rootfs")/g" \
	-e "s/@ARCHIVE_SHA@/$(value artifact_sha256)/g" \
	-e "s/@IMAGE_BYTES@/$(value persistent_root_image_size)/g" \
	-e "s/@IMAGE_SHA@/$(value persistent_root_image_sha256)/g" \
	"$script_dir/../initramfs/init-installer.in" >"$work/initramfs/init"
grep -q '@[A-Z_]*@' "$work/initramfs/init" && fail template-unresolved
chmod 0755 "$work/initramfs/init"
find "$work/initramfs" -exec touch -h -d '@1788739200' {} +
(cd "$work/initramfs" && find . -print0 | LC_ALL=C sort -z | cpio --null -o -H newc --reproducible --owner=0:0 --quiet | gzip -n -9 >"$work/initramfs.gz")
cat "$kernel" "$dtb" >"$work/kernel-dtb"
cmdline='earlycon=efifb console=tty0 console=ttyMSM0,115200n8 fbcon=font:TER16x32 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 rdinit=/init loglevel=4 initcall_blacklist=lmh_driver_init panic=0 m1892.usb=acm-ncm'
mkbootimg --header_version 0 --kernel "$work/kernel-dtb" --ramdisk "$work/initramfs.gz" --cmdline "$cmdline" --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x01000000 --second_offset 0x00f00000 --tags_offset 0x100 --pagesize 4096 --os_version 8.1.0 --os_patch_level 2021-06-01 --output "$work/inner"
artifact=$output/m1892-installer-boot.img
mkbootimg --header_version 1 --kernel "$work/uefi" --ramdisk "$work/inner" --base 0 --kernel_offset 0x10000000 --ramdisk_offset 0x10000000 --second_offset 0 --tags_offset 0x10000000 --pagesize 2048 --os_version 9.0.0 --os_patch_level 2020-09-01 --output "$artifact"
avbtool add_hash_footer --image "$artifact" --partition_size 67108864 --partition_name boot --salt fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a
cp "$artifact" "$work/boot.img"
avbtool verify_image --image "$work/boot.img" >/dev/null
sha256sum "$artifact" >"$artifact.sha256"
printf 'stage=installer-boot\nstock_recovery_tail=absent\nvendor_firmware=absent\nuserdata_write=absent\nrootfs_sha256=%s\n' "$(value artifact_sha256)" >"$output/BUILD-METADATA.txt"
echo "artifact=$artifact"
sha256sum "$artifact"
echo M1892_INSTALLER_BOOT_PASS
