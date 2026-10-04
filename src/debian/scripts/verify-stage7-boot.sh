#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

accepted_boot=${1:-}
persistent_recovery=${2:-}
boot=${3:-}
evidence_dir=${4:-}
[ -f "$accepted_boot" ] && [ -f "$persistent_recovery" ] && [ -f "$boot" ] &&
	[ -n "$evidence_dir" ] || {
	echo "usage: $0 ACCEPTED_R498_BOOT PERSISTENT_RECOVERY STAGE7_BOOT EVIDENCE_DIR" >&2
	exit 2
}
fail() { echo "M1892_DEBIAN_STAGE7_BOOT_VERIFY_FAIL: $*" >&2; exit 1; }
for command in avbtool cmp cpio dd gzip mktemp python3 sha256sum stat; do
	command -v "$command" >/dev/null || fail "missing-command:$command"
done
[ "$(sha256sum "$accepted_boot" | awk '{print $1}')" = \
	3be84b46d6e90c890903d157ae9f9b0450213c2cc1f21807274c8df946b24942 ] ||
	fail accepted-boot-hash
[ "$(stat -c %s "$boot")" = 67108864 ] || fail boot-size
boot_dir=$(dirname "$boot")
[ -f "$boot_dir/SHA256SUMS" ] && [ -f "$boot_dir/BUILD-METADATA.txt" ] || fail sidecars
(cd "$boot_dir" && sha256sum -c SHA256SUMS) >/dev/null || fail sidecar-hash
grep -Fxq 'stage=7-persistent-normal-boot' "$boot_dir/BUILD-METADATA.txt" || fail metadata-stage
grep -Fxq 'root_mode=persistent-userdata' "$boot_dir/BUILD-METADATA.txt" || fail metadata-mode
[ "$(sed -n 's/^source_recovery_sha256=//p' "$boot_dir/BUILD-METADATA.txt")" = \
	"$(sha256sum "$persistent_recovery" | awk '{print $1}')" ] || fail recovery-binding

work=$(mktemp -d /tmp/m1892-debian-stage7-boot-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/initramfs" "$evidence_dir"
cp "$boot" "$work/boot.img"
avbtool info_image --image "$work/boot.img" >"$evidence_dir/avb-info.txt" 2>&1 || fail avb-info
avbtool verify_image --image "$work/boot.img" >"$evidence_dir/avb-verify.txt" 2>&1 || fail avb-verify
grep -Eq '^Algorithm:[[:space:]]+NONE$' "$evidence_dir/avb-info.txt" || fail avb-algorithm
grep -Eq '^[[:space:]]+Partition Name:[[:space:]]+boot$' "$evidence_dir/avb-info.txt" ||
	fail avb-partition
grep -Eq '^[[:space:]]+Salt:[[:space:]]+fc5e6fa1efbd6ebaf16a6ac186f72d5ebfc86316b1ffe568470fdd5d84945d6a$' \
	"$evidence_dir/avb-info.txt" || fail avb-salt

python3 - "$accepted_boot" "$persistent_recovery" "$boot" "$work" <<'PY'
import struct, sys

def outer(path):
    raw = open(path, 'rb').read()
    if raw[:8] != b'ANDROID!':
        raise SystemExit('outer-magic')
    ks, rs, ps = (struct.unpack_from('<I', raw, off)[0] for off in (8, 16, 36))
    ko = ps
    ro = ps + ((ks + ps - 1) // ps) * ps
    end = ro + ((rs + ps - 1) // ps) * ps
    return raw, ko, ks, ro, rs, end

a, ako, aks, _, _, _ = outer(sys.argv[1])
r, rko, rks, rro, rrs, rend = outer(sys.argv[2])
b, bko, bks, bro, brs, bend = outer(sys.argv[3])
if not (rend == bend and rks == bks and rrs == brs):
    raise SystemExit('payload-layout')
open(sys.argv[4] + '/accepted-uefi', 'wb').write(a[ako:ako+aks])
open(sys.argv[4] + '/recovery-uefi', 'wb').write(r[rko:rko+rks])
open(sys.argv[4] + '/boot-uefi', 'wb').write(b[bko:bko+bks])
open(sys.argv[4] + '/recovery-prefix', 'wb').write(r[:rend])
open(sys.argv[4] + '/boot-prefix', 'wb').write(b[:bend])
inner = b[bro:bro+brs]
if inner[:8] != b'ANDROID!':
    raise SystemExit('inner-magic')
iks, irs, ips = (struct.unpack_from('<I', inner, off)[0] for off in (8, 16, 36))
iro = ips + ((iks + ips - 1) // ips) * ips
open(sys.argv[4] + '/initramfs.gz', 'wb').write(inner[iro:iro+irs])
PY
cmp -s "$work/accepted-uefi" "$work/recovery-uefi" || fail accepted-recovery-uefi
cmp -s "$work/accepted-uefi" "$work/boot-uefi" || fail accepted-boot-uefi
cmp -s "$work/recovery-prefix" "$work/boot-prefix" || fail recovery-boot-payload
gzip -dc "$work/initramfs.gz" >"$work/initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/initramfs.cpio")
init=$work/initramfs/init
grep -Fxq 'root_mode=persistent-userdata' "$init" || fail init-mode
grep -Fxq 'persistent_label=M1892_DEB13' "$init" || fail init-label
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' "$init" || fail init-uuid
grep -Fq 'normalize_core_device_permissions()' "$init" || fail init-device-mode
grep -Eq 'mkfs|resize2fs|e2fsck' "$init" && fail init-destructive-command

cat >"$evidence_dir/verification.env" <<EOF
result=pass
boot_sha256=$(sha256sum "$boot" | awk '{print $1}')
recovery_sha256=$(sha256sum "$persistent_recovery" | awk '{print $1}')
payload_identical=yes
uefi_identical_to_accepted_r498=yes
root_mode=persistent-userdata
avb_partition=boot
avb_algorithm=NONE
device_operation_performed=no
EOF
cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_STAGE7_BOOT_VERIFY_PASS
