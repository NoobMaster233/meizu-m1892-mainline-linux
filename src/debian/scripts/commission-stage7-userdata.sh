#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

mode=${1:-}
case "$mode" in
	--check) mode=check; shift ;;
	--flash)
		[ "${2:-}" = ERASE-M1892-USERDATA ] || {
			echo 'M1892_DEBIAN_STAGE7_COMMISSION_FAIL: explicit-erase-token-required' >&2
			exit 2
		}
		mode=commission; shift 2
		;;
	*)
		echo "usage: $0 --check | --flash ERASE-M1892-USERDATA ARCHIVE ARCHIVE_SHA IMAGE_SHA IMAGE_BYTES" >&2
		exit 2
		;;
esac
archive=${1:-}
expected_archive_sha=${2:-}
expected_image_sha=${3:-}
expected_image_bytes=${4:-}
device_firmware=${5:-}
target=/dev/sda19
fail() { echo "M1892_DEBIAN_STAGE7_COMMISSION_FAIL: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail not-root
[ -f "$archive" ] || fail archive-absent
for command in awk blkid blockdev dd e2fsck findmnt gzip grep mount readlink resize2fs sha256sum sync umount; do
	command -v "$command" >/dev/null || fail "missing-command:$command"
done
printf '%s\n%s\n' "$expected_archive_sha" "$expected_image_sha" |
	grep -Eqv '^[a-f0-9]{64}$' && fail invalid-hash
case "$expected_image_bytes" in ''|*[!0-9]*) fail invalid-image-size ;; esac
[ "${#expected_image_bytes}" -le 15 ] || fail oversized-number
[ "$expected_image_bytes" -ge 3221225472 ] &&
	[ "$expected_image_bytes" -le 8589934592 ] || fail unexpected-image-size
[ $((expected_image_bytes % 4194304)) -eq 0 ] || fail image-size-alignment
[ "$(cat /proc/1/comm)" = systemd ] || fail pid1
grep -Eq '^rootfs_id=m1892-debian13-(stage3|installer)-ram$' /etc/m1892-rootfs-identity || fail commissioning-root
[ "$(tr -d '\000' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] ||
	fail model
# A failed retry must never leave an earlier successful receipt usable.
if [ "$mode" = commission ]; then
	rm -f /run/m1892-stage7-commission.pass /run/m1892-stage7-commission.pass.tmp
fi
transaction_manifest_sha256=legacy
firmware_contract_sha256=legacy
if [ -n "$device_firmware" ]; then
	[ -f /run/m1892-package-manifest.json ] || fail public-manifest-absent
	transaction_manifest_sha256=$(sha256sum /run/m1892-package-manifest.json | awk '{print $1}')
	firmware_contract_sha256=$(sha256sum /usr/share/m1892/installer-firmware/firmware-files.tsv | awk '{print $1}')
fi
[ "$(cat /sys/class/block/sda19/partition)" = 19 ] || fail partition-number
grep -Fxq 'PARTNAME=userdata' /sys/class/block/sda19/uevent || fail partlabel
[ "$(readlink -f /dev/disk/by-partlabel/userdata)" = "$target" ] || fail userdata-alias
geometry_lib=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib/commissioning-geometry.sh
[ -r "$geometry_lib" ] || fail geometry-library-absent
. "$geometry_lib"
target_bytes=$(blockdev --getsize64 "$target")
m1892_validate_userdata_geometry "$expected_image_bytes" \
	"$(cat /sys/class/block/sda19/start)" "$(cat /sys/class/block/sda19/size)" \
	"$(cat /sys/class/block/sda/queue/logical_block_size)" "$target_bytes" || fail userdata-geometry
findmnt -rn -S "$target" | grep -q . && fail target-mounted
findmnt -rn -o SOURCE / | grep -Eq '^/dev/loop[0-9]+$' || fail root-not-loopback
[ "$(sha256sum "$archive" | awk '{print $1}')" = "$expected_archive_sha" ] || fail archive-hash
if [ -n "$device_firmware" ]; then
	/usr/libexec/m1892/install-device-firmware verify "$device_firmware" || fail device-firmware
fi
if [ "$mode" = check ]; then
	echo "target=$target"
	echo "archive_sha256=$expected_archive_sha"
	echo "source_image_sha256=$expected_image_sha"
	echo "target_bytes=$target_bytes"
	echo M1892_DEBIAN_STAGE7_COMMISSION_CHECK_PASS
	exit 0
fi

for service in udisks2.service udisks2-zram-setup@zram0.service; do
	systemctl stop "$service" 2>/dev/null || true
done
findmnt -rn -S "$target" | grep -q . && fail target-mounted-after-stop
gzip -dc "$archive" | dd of="$target" bs=4M conv=fsync status=progress
sync
blockdev --flushbufs "$target" || fail userdata-cache-flush
image_count=$((expected_image_bytes / 4194304))
after_image=$(dd if="$target" bs=4M count="$image_count" status=none |
	sha256sum | awk '{print $1}')
[ "$after_image" = "$expected_image_sha" ] || fail image-readback-hash
status=0
e2fsck -fy "$target" || status=$?
case "$status" in 0|1) ;; *) fail "e2fsck-repair:$status" ;; esac
resize2fs "$target"
e2fsck -fn "$target" >/run/m1892-stage7-e2fsck.log 2>&1 || fail e2fsck-final
[ "$(blkid -s TYPE -o value "$target")" = ext4 ] || fail final-type
[ "$(blkid -s LABEL -o value "$target")" = M1892_DEB13 ] || fail final-label
[ "$(blkid -s UUID -o value "$target")" = de131892-0000-4000-8000-000000000007 ] ||
	fail final-uuid
check_mount=/mnt/m1892-stage7-check
mkdir -p "$check_mount"
cleanup() { findmnt -rn -M "$check_mount" >/dev/null 2>&1 && umount "$check_mount" || true; }
trap cleanup EXIT HUP INT TERM
mount -t ext4 -o ro,noload "$target" "$check_mount"
grep -Fxq 'rootfs_id=m1892-debian13-stage7-persistent' \
	"$check_mount/etc/m1892-rootfs-identity" || fail mounted-identity
[ -x "$check_mount/usr/lib/systemd/systemd" ] || fail mounted-systemd
[ -x "$check_mount/usr/libexec/m1892/q6voiced" ] || fail mounted-q6voiced
[ -x "$check_mount/usr/libexec/m1892/callaudiod" ] || fail mounted-callaudiod
umount "$check_mount"
if [ -n "$device_firmware" ]; then
	mount -t ext4 -o rw,noatime "$target" "$check_mount"
	/usr/libexec/m1892/install-device-firmware apply "$device_firmware" --root "$check_mount" || fail firmware-install
	umount "$check_mount"
	e2fsck -fn "$target" >/run/m1892-stage7-e2fsck-after-firmware.log 2>&1 || fail firmware-final-filesystem
fi
trap - EXIT HUP INT TERM
if [ -n "$device_firmware" ]; then
	[ "$(sha256sum /run/m1892-package-manifest.json | awk '{print $1}')" = "$transaction_manifest_sha256" ] || fail manifest-changed
fi
cat >/run/m1892-stage7-commission.pass.tmp <<EOF
result=pass
target=/dev/sda19
archive_sha256=$expected_archive_sha
source_image_sha256=$expected_image_sha
capacity_source=kernel-partition-geometry
filesystem_uuid=de131892-0000-4000-8000-000000000007
filesystem_label=M1892_DEB13
filesystem_bytes=$(blockdev --getsize64 "$target")
transaction_manifest_sha256=$transaction_manifest_sha256
firmware_contract_sha256=$firmware_contract_sha256
EOF
mv /run/m1892-stage7-commission.pass.tmp /run/m1892-stage7-commission.pass
cat /run/m1892-stage7-commission.pass
echo M1892_DEBIAN_STAGE7_COMMISSION_PASS
