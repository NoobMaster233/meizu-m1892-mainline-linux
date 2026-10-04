#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_recovery=${1:-}
recovery=${2:-}
rootfs=${3:-}
evidence_dir=${4:-}
[ -f "$source_recovery" ] && [ -f "$recovery" ] && [ -f "$rootfs" ] && \
	[ -n "$evidence_dir" ] || {
	echo "usage: $0 SOURCE_RECOVERY STAGE2_RECOVERY ROOTFS_EXT4_GZ EVIDENCE_DIR" >&2
	exit 2
}
fail() { echo "M1892_DEBIAN_STAGE2_VERIFY_FAIL: $*" >&2; exit 1; }
[ "$(stat -c %s "$source_recovery")" = 67108864 ] || fail source-size
[ "$(stat -c %s "$recovery")" = 67108864 ] || fail recovery-size
[ -f "$rootfs.sha256" ] || fail rootfs-sidecar
(cd "$(dirname -- "$rootfs")" && sha256sum -c "$(basename -- "$rootfs").sha256") >/dev/null || fail rootfs-hash

work=$(mktemp -d /tmp/m1892-debian-stage2-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/rootfs" "$work/initramfs" "$evidence_dir"
dd if="$source_recovery" of="$work/source-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
dd if="$recovery" of="$work/output-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
cmp -s "$work/source-tail" "$work/output-tail" || fail stock-tail-changed

python3 - "$recovery" "$work" <<'PY'
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
open(sys.argv[2] + '/initramfs.gz', 'wb').write(inner[iro:iro + irs])
open(sys.argv[2] + '/cmdline', 'wb').write(cmd)
PY
case $(cat "$work/cmdline") in *'m1892.usb=acm-ncm'*) ;; *) fail usb-cmdline ;; esac
gzip -dc "$work/initramfs.gz" >"$work/initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/initramfs.cpio")
init=$work/initramfs/init
[ -x "$init" ] || fail init-absent
grep -Fq 'm1892-debian13-stage2-rootfs.ext4.gz' "$init" || fail wrong-init
grep -Fq "expected_bytes=$(stat -c %s "$rootfs")" "$init" || fail rootfs-size-contract
grep -Fq "expected_sha256=$(sha256sum "$rootfs" | awk '{print $1}')" "$init" || fail rootfs-hash-contract
rootfs_metadata=$(dirname -- "$rootfs")/BUILD-METADATA.txt
[ -r "$rootfs_metadata" ] || fail rootfs-metadata-absent
image_bytes=$(sed -n 's/^persistent_root_image_size=//p' "$rootfs_metadata")
image_sha=$(sed -n 's/^persistent_root_image_sha256=//p' "$rootfs_metadata")
grep -Fq "expected_image_bytes=$image_bytes" "$init" || fail rootfs-image-size-contract
grep -Fq "expected_image_sha256=$image_sha" "$init" || fail rootfs-image-hash-contract
grep -Fq 'losetup "$loopdev" "$root_image"' "$init" || fail loopback-setup-absent
grep -Fq 'mount -t ext4 -o rw,noatime "$loopdev" "$newroot"' "$init" || fail loopback-mount-absent
panel=$work/initramfs/lib/modules/m1892-panel/panel-samsung-sofef00m.ko
[ -f "$panel" ] || fail panel-module-absent
[ "$(sha256sum "$panel" | awk '{print $1}')" = \
	be7fd48b47e58d63f534aa968665477932d86559cd0122dbbd99b52a55717fe1 ] || \
	fail panel-module-hash
grep -Fq 'insmod "$panel_module"' "$init" || fail panel-module-loader-absent
grep -Fq '[ -e /sys/class/drm/card0 ] && [ -e /dev/dri/renderD128 ]' "$init" || \
	fail drm-runtime-gate-absent
grep -Fq 'printf '\''%s\n'\'' "$machine_id" >"$newroot/etc/machine-id"' "$init" || fail transient-machine-id-absent
grep -Fq 'exec switch_root -c /dev/console "$newroot" /sbin/init' "$init" || fail systemd-switch-root-absent
if grep -Eq 'mount[^\n]*/dev/sda19|mkfs|resize2fs|e2fsck' "$init"; then fail persistent-storage-command; fi

gzip -dc "$rootfs" >"$work/rootfs.ext4"
[ "$(stat -c %s "$work/rootfs.ext4")" = "$image_bytes" ] || fail rootfs-image-size
[ "$(sha256sum "$work/rootfs.ext4" | awk '{print $1}')" = "$image_sha" ] || fail rootfs-image-hash
e2fsck -fn "$work/rootfs.ext4" >"$evidence_dir/e2fsck.log" 2>&1 || fail rootfs-e2fsck
[ "$(blkid -s TYPE -o value "$work/rootfs.ext4")" = ext4 ] || fail rootfs-not-ext4
[ "$(blkid -s LABEL -o value "$work/rootfs.ext4")" = M1892_DEB13_S2 ] || fail rootfs-label
debugfs -R "rdump / $work/rootfs" "$work/rootfs.ext4" >/dev/null 2>&1 || fail rootfs-extract
fs_owner()
{
	debugfs -R "stat $1" "$work/rootfs.ext4" 2>/dev/null |
		awk '/^User:/ { print $2 ":" $4; exit }'
}
for root_owned in /etc /usr /usr/lib /var /var/lib /var/log \
	/usr/lib/aarch64-linux-gnu/NetworkManager/1.52.1/libnm-device-plugin-wifi.so; do
	[ "$(fs_owner "$root_owned")" = 0:0 ] || fail "rootfs-owner:$root_owned"
done
grep -Fxq 'rootfs_id=m1892-debian13-stage2-ram' \
	"$work/rootfs/etc/m1892-rootfs-identity" || fail rootfs-identity
[ -x "$work/rootfs/usr/lib/systemd/systemd" ] || fail systemd-absent
[ -x "$work/rootfs/usr/libexec/m1892/stage2-acceptance" ] || fail acceptance-absent
for unit in m1892-stage2-acceptance.service m1892-stage2-acm-shell.service; do
	[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/$unit" ] || fail "unit-not-enabled:$unit"
done
[ ! -e "$work/rootfs/etc/hostname" ] || fail hostname-present
find "$work/rootfs/etc/NetworkManager/system-connections" -mindepth 1 -print -quit \
	2>/dev/null | grep -q . && fail private-network-profile
find "$work/rootfs/root" "$work/rootfs/home" -path '*/.ssh/*' -print -quit \
	2>/dev/null | grep -q . && fail owner-ssh-data

{
	printf 'result=pass\n'
	printf 'recovery_sha256=%s\n' "$(sha256sum "$recovery" | awk '{print $1}')"
	printf 'rootfs_sha256=%s\n' "$(sha256sum "$rootfs" | awk '{print $1}')"
	printf 'stock_tail_changed=no\n'
	printf 'persistent_boot_modified=no\nuserdata_modified=no\n'
	printf 'systemd_switch_root=present\n'
	printf 'root_mode=ram-loopback\n'
	printf 'development_usb=acm-ncm\n'
	printf 'panel_module=accepted-k1-sofef00m\n'
	printf 'rootfs_system_ownership=root\n'
} >"$evidence_dir/verification.env"
cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_STAGE2_ARTIFACT_VERIFY_PASS
