#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
base=${1:-} output=${2:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
fail() { echo "M1892_INSTALLER_ROOTFS_FAIL: $*" >&2; exit 1; }
[ -f "$base" ] && [ -n "$output" ] || fail arguments
case "$output" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output" ] || fail output-exists
for command in fakeroot tar install truncate mkfs.ext4 debugfs e2fsck sha256sum gzip; do
	command -v "$command" >/dev/null || fail "missing-command:$command"
done
if [ "${M1892_INSTALLER_FAKEROOT:-0}" != 1 ]; then
	exec fakeroot -- env M1892_INSTALLER_FAKEROOT=1 "$0" "$@"
fi
[ -f "$base.sha256" ] || fail sidecar-absent
(cd "$(dirname "$base")" && sha256sum -c "$(basename "$base").sha256") >/dev/null || fail base-hash
work=$(mktemp -d /tmp/m1892-installer-rootfs.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output"
# Account database backups are build-time files, not installation state. Some
# Debian postinsts create them with mode 0000, which a rootless ext4 population
# cannot read; do not weaken their permissions or bake those backups into RAM.
tar --same-owner --numeric-owner --exclude='./dev/*' --exclude='./etc/shadow-' \
 --exclude='./etc/gshadow-' --exclude='./etc/passwd-' --exclude='./etc/group-' -xf "$base" -C "$root"
for executable in /usr/sbin/e2fsck /usr/sbin/resize2fs /usr/bin/python3 /usr/bin/unzip /usr/bin/busybox; do
	[ -x "$root$executable" ] || fail "runtime:$executable"
done
install -d "$root/dev" "$root/etc/systemd/system/multi-user.target.wants" "$root/usr/libexec/m1892/lib"
printf '%s\n' 'rootfs_id=m1892-debian13-installer-ram' 'distribution=debian' 'version=13' 'architecture=arm64' 'root_mode=ram-loopback' >"$root/etc/m1892-rootfs-identity"
cat >"$root/etc/systemd/system/m1892-installer-acm-shell.service" <<'EOF'
[Unit]
Description=M1892 explicit RAM installation control console
Requires=dev-ttyGS0.device
After=dev-ttyGS0.device
[Service]
ExecStart=/bin/sh -l
StandardInput=tty-force
StandardOutput=tty
StandardError=tty
TTYPath=/dev/ttyGS0
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=1
KillSignal=SIGHUP
SendSIGHUP=yes
TimeoutStopSec=5s
[Install]
WantedBy=multi-user.target
EOF
ln -s ../m1892-installer-acm-shell.service "$root/etc/systemd/system/multi-user.target.wants/m1892-installer-acm-shell.service"
install -m 0755 "$script_dir/commission-stage7-userdata.sh" "$root/usr/libexec/m1892/commission-stage7-userdata"
install -m 0644 "$script_dir/lib/commissioning-geometry.sh" "$root/usr/libexec/m1892/lib/commissioning-geometry.sh"
# The installation environment never automatically suspends or trims a target.
for target in sleep.target suspend.target hibernate.target fstrim.timer; do
	ln -snf /dev/null "$root/etc/systemd/system/$target"
done
epoch=1788739200
uuid=de131892-0000-4000-8000-000000000020
image=$work/installer.ext4
find "$root" -xdev -exec touch -h -d "@$epoch" {} +
truncate -s 536870912 "$image"
E2FSPROGS_FAKE_TIME=$epoch mkfs.ext4 -q -F -m 0 -L M1892_INSTALL -U "$uuid" \
	-E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$image"
E2FSPROGS_FAKE_TIME=$epoch debugfs -w -R "set_super_value hash_seed $uuid" "$image" >/dev/null 2>&1
e2fsck -fn "$image" >"$output/e2fsck.log" 2>&1 || fail filesystem
raw_sha=$(sha256sum "$image" | awk '{print $1}')
artifact=$output/m1892-installer-rootfs.ext4.gz
gzip -n -6 <"$image" >"$artifact"
sha=$(sha256sum "$artifact" | awk '{print $1}')
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
cat >"$output/BUILD-METADATA.txt" <<EOF
stage=installer-ram
root_mode=ram-loopback
artifact_sha256=$sha
artifact_size=$(stat -c %s "$artifact")
persistent_root_image_size=536870912
persistent_root_image_sha256=$raw_sha
filesystem_uuid=$uuid
vendor_firmware=absent
owner_credentials=absent
EOF
echo "artifact=$artifact"
cat "$output/BUILD-METADATA.txt"
echo M1892_INSTALLER_ROOTFS_PASS
