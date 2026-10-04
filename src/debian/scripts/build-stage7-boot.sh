#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

accepted_boot=${1:-}
persistent_recovery=${2:-}
output_dir=${3:-}
[ -f "$accepted_boot" ] && [ -f "$persistent_recovery" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 ACCEPTED_R498_BOOT PERSISTENT_RECOVERY ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_STAGE7_BOOT_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ ! -e "$output_dir" ] || { echo 'M1892_DEBIAN_STAGE7_BOOT_FAIL: output-exists' >&2; exit 1; }

accepted_boot_sha=3be84b46d6e90c890903d157ae9f9b0450213c2cc1f21807274c8df946b24942
accepted_uefi_sha=1d3312dc255cc9d123c906fb456f6260b0b10dc3564fed7418c64c20c53e967b
boot_salt=fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a
partition_size=67108864
fail() { echo "M1892_DEBIAN_STAGE7_BOOT_FAIL: $*" >&2; exit 1; }
for command in avbtool cmp cpio dd gzip mktemp python3 sha256sum stat; do
	command -v "$command" >/dev/null || fail "missing-command:$command"
done
[ "$(sha256sum "$accepted_boot" | awk '{print $1}')" = "$accepted_boot_sha" ] ||
	fail accepted-boot-hash
[ "$(stat -c %s "$accepted_boot")" = "$partition_size" ] || fail accepted-boot-size
[ "$(stat -c %s "$persistent_recovery")" = "$partition_size" ] || fail recovery-size
recovery_dir=$(dirname "$persistent_recovery")
[ -f "$recovery_dir/SHA256SUMS" ] && [ -f "$recovery_dir/BUILD-METADATA.txt" ] ||
	fail recovery-sidecars
(cd "$recovery_dir" && sha256sum -c SHA256SUMS) >/dev/null || fail recovery-sidecar-hash
grep -Fxq 'root_mode=persistent-userdata' "$recovery_dir/BUILD-METADATA.txt" ||
	fail recovery-root-mode
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' \
	"$recovery_dir/BUILD-METADATA.txt" || fail recovery-uuid

work=$(mktemp -d /tmp/m1892-debian-stage7-boot.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/initramfs" "$output_dir"

python3 - "$accepted_boot" "$persistent_recovery" "$work" <<'PY'
import struct, sys

def outer(path):
    raw = open(path, 'rb').read()
    if raw[:8] != b'ANDROID!':
        raise SystemExit('outer-magic')
    kernel_size = struct.unpack_from('<I', raw, 8)[0]
    ramdisk_size = struct.unpack_from('<I', raw, 16)[0]
    page_size = struct.unpack_from('<I', raw, 36)[0]
    kernel_off = page_size
    ramdisk_off = page_size + ((kernel_size + page_size - 1) // page_size) * page_size
    payload_end = ramdisk_off + ((ramdisk_size + page_size - 1) // page_size) * page_size
    return raw, kernel_off, kernel_size, ramdisk_off, ramdisk_size, payload_end

accepted, a_ko, a_ks, _, _, _ = outer(sys.argv[1])
recovery, r_ko, r_ks, r_ro, r_rs, r_end = outer(sys.argv[2])
open(sys.argv[3] + '/accepted-uefi', 'wb').write(accepted[a_ko:a_ko+a_ks])
open(sys.argv[3] + '/recovery-uefi', 'wb').write(recovery[r_ko:r_ko+r_ks])
open(sys.argv[3] + '/payload', 'wb').write(recovery[:r_end])
inner = recovery[r_ro:r_ro+r_rs]
if inner[:8] != b'ANDROID!':
    raise SystemExit('inner-magic')
iks = struct.unpack_from('<I', inner, 8)[0]
irs = struct.unpack_from('<I', inner, 16)[0]
ips = struct.unpack_from('<I', inner, 36)[0]
iro = ips + ((iks + ips - 1) // ips) * ips
open(sys.argv[3] + '/initramfs.gz', 'wb').write(inner[iro:iro+irs])
with open(sys.argv[3] + '/layout.env', 'w', encoding='ascii') as out:
    out.write(f'payload_size={r_end}\n')
PY
. "$work/layout.env"
[ "$(sha256sum "$work/accepted-uefi" | awk '{print $1}')" = "$accepted_uefi_sha" ] ||
	fail accepted-uefi-hash
cmp -s "$work/accepted-uefi" "$work/recovery-uefi" || fail recovery-uefi-differs
gzip -dc "$work/initramfs.gz" >"$work/initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/initramfs.cpio")
init=$work/initramfs/init
grep -Fxq 'root_mode=persistent-userdata' "$init" || fail init-root-mode
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' "$init" ||
	fail init-uuid
grep -Fq 'normalize_core_device_permissions()' "$init" || fail init-device-mode

boot=$output_dir/m1892-debian13-stage7-persistent-boot-local.img
cp "$work/payload" "$boot"
avbtool add_hash_footer --image "$boot" --partition_size "$partition_size" \
	--partition_name boot --salt "$boot_salt"
[ "$(stat -c %s "$boot")" = "$partition_size" ] || fail output-size
cp "$boot" "$work/boot.img"
avbtool verify_image --image "$work/boot.img" >/dev/null || fail avb-verify
dd if="$boot" of="$work/output-prefix" bs=1M iflag=count_bytes count="$payload_size" status=none
cmp -s "$work/payload" "$work/output-prefix" || fail payload-prefix-changed

cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=7-persistent-normal-boot
source_boot_sha256=$accepted_boot_sha
source_recovery_sha256=$(sha256sum "$persistent_recovery" | awk '{print $1}')
source_recovery_metadata_sha256=$(sha256sum "$recovery_dir/BUILD-METADATA.txt" | awk '{print $1}')
uefi_sha256=$accepted_uefi_sha
payload_sha256=$(sha256sum "$work/payload" | awk '{print $1}')
payload_size=$payload_size
root_mode=persistent-userdata
persistent_uuid=de131892-0000-4000-8000-000000000007
persistent_label=M1892_DEB13
partition_name=boot
partition_size=$partition_size
avb_algorithm=NONE
avb_salt=$boot_salt
device_operation_performed=no
EOF
(cd "$output_dir" && sha256sum "$(basename "$boot")" BUILD-METADATA.txt >SHA256SUMS)
echo "boot=$boot"
echo "boot_sha256=$(sha256sum "$boot" | awk '{print $1}')"
echo M1892_DEBIAN_STAGE7_BOOT_BUILD_PASS
echo 'No device operation was performed.'
