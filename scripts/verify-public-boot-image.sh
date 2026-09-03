#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

boot=${1:-}
kernel=${2:-}
dtb=${3:-}
uefi_loader=${4:-}
uefi_manifest=${5:-}
fail() { echo "M1892_PUBLIC_BOOT_VERIFY_FAIL: $*" >&2; exit 1; }
for file in "$boot" "$kernel" "$dtb" "$uefi_loader" "$uefi_manifest"; do
	[ -f "$file" ] || fail "missing-input:$file"
done
for command in avbtool awk cmp cp cpio fdtget find gzip python3 readlink \
	sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ "$(stat -c %s "$boot")" = 67108864 ] || fail boot-size
[ "$(sha256sum "$kernel" | awk '{print $1}')" = \
	4e1fbf09d05f342da25e9cfcb29ea6fc973c05f31cec3992819455895423856c ] ||
	fail kernel-hash
[ "$(sha256sum "$dtb" | awk '{print $1}')" = \
	4e09e9aaac03503bd9c76afa7c1b602bad43227b6d96bd15f7abef5ac02244f4 ] ||
	fail dtb-hash

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-public-boot-verify.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
# avbtool resolves the descriptor partition name relative to the supplied
# filename during verify_image, so use the canonical boot.img basename.
cp "$boot" "$work/boot.img"
avb_info=$(avbtool info_image --image "$work/boot.img") || fail avb-info
printf '%s\n' "$avb_info" | grep -q '^Algorithm:[[:space:]]*NONE$' || fail avb-algorithm
printf '%s\n' "$avb_info" | grep -q '^      Partition Name:[[:space:]]*boot$' || fail avb-partition
printf '%s\n' "$avb_info" | grep -q '^      Salt:[[:space:]]*fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a$' || fail avb-salt
avbtool verify_image --image "$work/boot.img" >/dev/null || fail avb-verify

# Parse only the two Android boot headers and copy their declared components.
# This intentionally does not call the image maker or trust its intermediate
# files, so the verification path remains independent of the build path.
python3 - "$boot" "$work" <<'PY'
import pathlib, struct, sys

def unpack(image, output, prefix):
    data = pathlib.Path(image).read_bytes()
    if data[:8] != b"ANDROID!":
        raise SystemExit(f"{prefix}: bad boot magic")
    kernel_size, ramdisk_size = struct.unpack_from("<I4xI", data, 8)
    page_size, header_version = struct.unpack_from("<II", data, 36)
    if page_size not in (2048, 4096):
        raise SystemExit(f"{prefix}: unexpected page size {page_size}")
    kernel_offset = page_size
    ramdisk_offset = kernel_offset + ((kernel_size + page_size - 1) // page_size) * page_size
    end = ramdisk_offset + ramdisk_size
    if end > len(data):
        raise SystemExit(f"{prefix}: component exceeds image")
    pathlib.Path(output, f"{prefix}.kernel").write_bytes(data[kernel_offset:kernel_offset + kernel_size])
    pathlib.Path(output, f"{prefix}.ramdisk").write_bytes(data[ramdisk_offset:end])
    cmdline = data[64:576].rstrip(b"\0") + data[608:1632].rstrip(b"\0")
    pathlib.Path(output, f"{prefix}.meta").write_text(
        f"page_size={page_size}\nheader_version={header_version}\n"
        f"kernel_size={kernel_size}\nramdisk_size={ramdisk_size}\n"
        f"cmdline={cmdline.decode('ascii')}\n", encoding="ascii")

boot, out = sys.argv[1:]
unpack(boot, out, "outer")
unpack(pathlib.Path(out, "outer.ramdisk"), out, "inner")
PY

grep -qx 'page_size=2048' "$work/outer.meta" || fail outer-page-size
grep -qx 'header_version=1' "$work/outer.meta" || fail outer-header-version
grep -qx 'cmdline=' "$work/outer.meta" || fail outer-cmdline
cmp -s "$work/outer.kernel" "$uefi_loader" || fail uefi-loader-content

manifest_value()
{
	key=$1
	awk -F= -v key="$key" '$1==key { if (++count > 1) exit 2; value=$2 }
		END { if (count != 1) exit 1; print value }' "$uefi_manifest" ||
		fail "uefi-manifest:$key"
}
[ "$(manifest_value format)" = m1892-public-edk2-loader-v1 ] || fail manifest-format
[ "$(manifest_value edk2_sdm845_commit)" = e1952621f419f8db60ed28271264e1b5184c571d ] || fail manifest-edk2
[ "$(manifest_value edk2_commit)" = e7aac7fc137e247edad22f7ee53b9a1fba227397 ] || fail manifest-edk2-submodule
[ "$(manifest_value edk2_platforms_commit)" = 982212662c71b6c734b7578526071d6b78da3bcc ] || fail manifest-edk2-platforms
[ "$(manifest_value simpleinit_commit)" = 29e062805776db5ab7a61d07ef040d43aed71161 ] || fail manifest-simpleinit
[ "$(manifest_value freetype_commit)" = 6a2b3e4007e794bfc6c91030d0ed987f925164a8 ] || fail manifest-freetype
[ "$(manifest_value basetools_brotli_commit)" = f4153a09f87cbb9c826d8fc12c74642bb2d879ea ] || fail manifest-basetools-brotli
[ "$(manifest_value static_config_sha256)" = 644d43c5ec4d93a56c2b9beab55562e75b43124ff381cf1f5d64a11e64543787 ] || fail manifest-static-config
[ "$(manifest_value edk2_patch_sha256)" = 4ea1ce45ec3a8741ca8984a4e1f0e6104a904a63d32da34f9c0c3e452ff87441 ] || fail manifest-edk2-patch
[ "$(manifest_value simpleinit_fdt_patch_sha256)" = 8741442511fd98840e86a588cd38b7a7ac73593d3060771fca1c6546e4737daf ] || fail manifest-simpleinit-fdt-patch
[ "$(manifest_value simpleinit_hold_patch_sha256)" = 7d006b53fdac41a99bee2645afab1c84868c37f3c6224d5e834fc491b70d855f ] || fail manifest-simpleinit-hold-patch
manifest_hash=$(manifest_value uefi_loader_sha256)
[ "$(sha256sum "$uefi_loader" | awk '{print $1}')" = "$manifest_hash" ] ||
	fail manifest-loader-mismatch

grep -qx 'page_size=4096' "$work/inner.meta" || fail inner-page-size
grep -qx 'header_version=0' "$work/inner.meta" || fail inner-header-version
expected_cmdline='earlycon=efifb console=tty0 console=ttyMSM0,115200n8 fbcon=font:TER16x32 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.configfs=true androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 rdinit=/init loglevel=4 initcall_blacklist=lmh_driver_init panic=0 m1892.usb=off'
grep -qx "cmdline=$expected_cmdline" "$work/inner.meta" || fail inner-cmdline

cat "$kernel" "$dtb" >"$work/expected-kernel-dtb"
cmp -s "$work/inner.kernel" "$work/expected-kernel-dtb" || fail kernel-dtb-content
[ "$(fdtget -t s "$dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail dt-model
bluetooth=/soc@0/geniqup@8c0000/serial@898000/bluetooth
if fdtget "$dtb" "$bluetooth" local-bd-address >/dev/null 2>&1; then
	fail fixed-bluetooth-address
fi

gzip -t "$work/inner.ramdisk" || fail initramfs-gzip
mkdir "$work/initramfs"
(cd "$work/initramfs" && gzip -dc ../inner.ramdisk | cpio -id --quiet) || fail initramfs-extract
expected_entries='.
./bin
./bin/busybox
./bin/reboot-fastboot
./init
./lib
./lib/ld-musl-aarch64.so.1
./lib/libc.musl-aarch64.so.1'
actual_entries=$(cd "$work/initramfs" && find . -print | LC_ALL=C sort)
[ "$actual_entries" = "$expected_entries" ] || fail initramfs-entry-set
[ "$(sha256sum "$work/initramfs/bin/busybox" | awk '{print $1}')" = \
	efc0abd6cb598f0555017d868ed9222f80908757eb13159e786721d321e381a8 ] || fail busybox-hash
[ "$(sha256sum "$work/initramfs/bin/reboot-fastboot" | awk '{print $1}')" = \
	2b8eb06dcf71544e6ae7f189c37bd9bdd67c6f18e36d0fa44fa2e35814f989ba ] ||
	fail reboot-fastboot-hash
[ "$(sha256sum "$work/initramfs/lib/ld-musl-aarch64.so.1" | awk '{print $1}')" = \
	32377e6d71725bb019e9ff6d5e9f16b4d5156d6f2c36504191c2d6a7c4d4a44d ] || fail musl-hash
[ "$(readlink "$work/initramfs/lib/libc.musl-aarch64.so.1")" = \
	ld-musl-aarch64.so.1 ] || fail musl-link

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
init_source=$script_dir/../src/boot/init-r537-public-root
[ -r "$init_source" ] || fail missing-init-source
cmp -s "$work/initramfs/init" "$init_source" || fail init-content

printf 'boot_sha256=%s\n' "$(sha256sum "$boot" | awk '{print $1}')"
printf 'initramfs_sha256=%s\n' "$(sha256sum "$work/inner.ramdisk" | awk '{print $1}')"
echo M1892_PUBLIC_BOOT_VERIFY_PASS
