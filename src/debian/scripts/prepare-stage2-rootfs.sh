#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
base=${1:-}
output_dir=${2:-}
[ -f "$base" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 MINBASE_TAR ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_STAGE2_ROOTFS_FAIL: output-not-absolute' >&2; exit 2 ;; esac
if [ "${M1892_STAGE2_FAKEROOT:-0}" != 1 ]; then
	command -v fakeroot >/dev/null 2>&1 || {
		echo 'M1892_DEBIAN_STAGE2_ROOTFS_FAIL: missing-command:fakeroot' >&2
		exit 1
	}
	exec fakeroot -- env M1892_STAGE2_FAKEROOT=1 "$0" "$@"
fi
[ -f "$base.sha256" ] || { echo 'M1892_DEBIAN_STAGE2_ROOTFS_FAIL: base-sidecar-absent' >&2; exit 2; }
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256") >/dev/null || {
	echo 'M1892_DEBIAN_STAGE2_ROOTFS_FAIL: base-hash' >&2
	exit 1
}
[ ! -e "$output_dir" ] || { echo 'M1892_DEBIAN_STAGE2_ROOTFS_FAIL: output-exists' >&2; exit 1; }
for command in debugfs e2fsck find gzip install ln mkfs.ext4 mktemp \
	sha256sum stat tar touch truncate; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "M1892_DEBIAN_STAGE2_ROOTFS_FAIL: missing-command:$command" >&2
		exit 1
	}
done

work=$(mktemp -d /tmp/m1892-debian-stage2-rootfs.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output_dir"
# /dev is supplied by the devtmpfs moved from the recovery initramfs.  Do not
# reproduce archive device nodes in a rootless build environment.
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev"

overlay=$tree_dir/rootfs-overlay
install -d "$root/etc/NetworkManager/conf.d" "$root/etc/systemd/system" \
	"$root/usr/libexec/m1892" "$root/etc/systemd/system/multi-user.target.wants"
install -m 0644 "$overlay/etc/m1892-rootfs-identity" "$root/etc/m1892-rootfs-identity"
install -m 0644 "$overlay/etc/NetworkManager/conf.d/80-m1892-stage2-usb.conf" \
	"$root/etc/NetworkManager/conf.d/80-m1892-stage2-usb.conf"
for unit in m1892-stage2-acceptance.service m1892-stage2-acm-shell.service; do
	install -m 0644 "$overlay/etc/systemd/system/$unit" "$root/etc/systemd/system/$unit"
	ln -s "../$unit" "$root/etc/systemd/system/multi-user.target.wants/$unit"
done
install -m 0755 "$overlay/usr/libexec/m1892/stage2-acceptance" \
	"$root/usr/libexec/m1892/stage2-acceptance"
# Host keys and owner authorization are intentionally absent in this generic
# RAM-root.  Keep ssh installed for later stages, but do not leave a knowingly
# failing daemon enabled before owner initialization exists.
rm -f "$root/etc/systemd/system/multi-user.target.wants/ssh.service" \
	"$root/etc/systemd/system/multi-user.target.wants/sshd.service"

# The development artifact is generic: no owner, password, key, network or
# persistent identity is injected.  Its privileged console exists only on the
# recovery ACM link and is removed from later product stages.
source_date_epoch=1788739200
find "$root" -xdev -exec touch -h -d "@$source_date_epoch" {} +
image=$work/m1892-debian13-stage2-rootfs.ext4
image_bytes=536870912
filesystem_uuid=de131892-0000-4000-8000-000000000002
truncate -s "$image_bytes" "$image"
E2FSPROGS_FAKE_TIME=$source_date_epoch mkfs.ext4 -q -F -m 0 \
	-L M1892_DEB13_S2 -U "$filesystem_uuid" \
	-E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$image"
E2FSPROGS_FAKE_TIME=$source_date_epoch debugfs -w -R \
	"set_super_value hash_seed $filesystem_uuid" "$image" >/dev/null 2>&1
E2FSPROGS_FAKE_TIME=$source_date_epoch e2fsck -fn "$image" >"$output_dir/e2fsck.log" 2>&1

image_sha=$(sha256sum "$image" | awk '{print $1}')
artifact=$output_dir/m1892-debian13-stage2-rootfs.ext4.gz
gzip -n -6 <"$image" >"$artifact"

sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=2-systemd-ram-root
base_sha256=$(sha256sum "$base" | awk '{print $1}')
artifact_sha256=$sha
artifact_size=$bytes
root_mode=ram-loopback
persistent_root_format=ext4-loopback
persistent_root_image_size=$image_bytes
persistent_root_image_sha256=$image_sha
filesystem_uuid=$filesystem_uuid
persistent_storage_modified=no
owner_credentials_injected=no
development_console=acm-root-shell
ssh_policy=installed-disabled-until-owner-initialization
EOF
echo "artifact=$artifact"
echo "artifact_size=$bytes"
echo "artifact_sha256=$sha"
echo "rootfs_image_size=$image_bytes"
echo "rootfs_image_sha256=$image_sha"
echo M1892_DEBIAN_STAGE2_ROOTFS_BUILD_PASS
