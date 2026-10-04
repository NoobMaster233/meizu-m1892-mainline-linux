#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
plasma_settings_input=${2:-}
calamares_debs=${3:-}
output_dir=${4:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
base_sha=0fcf871e0ae072c937f996a85dad50e2bb0c032091e3fefa741e7484e32a602e
calamares_manifest_sha=a5e6993c7809538931c8a5077c5afaf15d61b192a8c536ca142d88010f7ee333
source_date_epoch=1788739200
artifact_name=m1892-debian13-plasma-mobile-stage6-oem-arm64.tar

fail() { echo "M1892_STAGE6_OEM_DERIVE_FAIL: $*" >&2; exit 1; }
[ -f "$base" ] && [ -d "$plasma_settings_input" ] &&
	[ -d "$calamares_debs" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_STAGE6_TAR PLASMA_SETTINGS_DEB_DIR CALAMARES_DEBS_DIR ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ "$(id -u)" = 0 ] || fail requires-root-build-environment
[ ! -e "$output_dir" ] || fail output-exists
[ -f "$base.sha256" ] || fail base-sidecar
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256" >/dev/null) ||
	fail base-sidecar
[ "$(sha256sum "$base" | awk '{print $1}')" = "$base_sha" ] || fail base-hash
"$script_dir/install-stage6-plasma-settings.sh" --check "$plasma_settings_input"
manifest=$calamares_debs/CALAMARES-DEBS.sha256
[ -f "$manifest" ] && [ "$(sha256sum "$manifest" | awk '{print $1}')" = \
	"$calamares_manifest_sha" ] || fail calamares-manifest
(cd "$calamares_debs" && sha256sum -c CALAMARES-DEBS.sha256 >/dev/null) ||
	fail calamares-deb-hash
[ "$(wc -l <"$manifest")" = 13 ] || fail calamares-deb-count
for command in basename chroot cp dpkg-deb find mkdir mktemp mount sha256sum stat tar touch \
	umount; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
actual_deb_count=$(find "$calamares_debs" -maxdepth 1 -type f -name '*.deb' | wc -l)
[ "$actual_deb_count" = 13 ] || fail calamares-extra-deb
while read -r hash file; do
	case "$hash:$file" in
		????????????????????????????????????????????????????????????????:*.deb) ;;
			*) fail calamares-manifest-entry ;;
	esac
	[ "$(basename -- "$file")" = "$file" ] || fail calamares-manifest-path
	case $(dpkg-deb -f "$calamares_debs/$file" Architecture) in arm64|all) ;; *)
		fail "calamares-architecture:$file" ;;
	esac
done <"$manifest"

work=$(mktemp -d /tmp/m1892-stage6-oem-derive.XXXXXXXX)
root=$work/root
mounted=no
completed=no
cleanup()
{
	if [ "$mounted" = yes ]; then
		umount -l "$root/dev" "$root/sys" "$root/proc" 2>/dev/null || true
	fi
	find "$work" -depth -delete 2>/dev/null || true
	if [ "$completed" = no ] && [ -d "$output_dir" ] &&
		[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		rmdir "$output_dir"
	fi
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$root" "$output_dir"
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
stage=$root/run/m1892-oem-debs
mkdir -p "$root/dev" "$root/proc" "$root/sys" "$stage"
while read -r _ file; do
	cp "$calamares_debs/$file" "$stage/$file"
done <"$manifest"
cp "$plasma_settings_input"/plasma-settings_26.02.0-0m1892.1_arm64.deb "$stage/"
mount --bind /proc "$root/proc"
mount --bind /sys "$root/sys"
mount --bind /dev "$root/dev"
mounted=yes
DEBIAN_FRONTEND=noninteractive chroot "$root" /bin/sh -c \
	'dpkg -i /run/m1892-oem-debs/*.deb' \
	>"$work/dpkg.log" 2>&1 || { tail -n 160 "$work/dpkg.log" >&2; fail dpkg-install; }
for pair in calamares=3.3.14-1 plasma-settings=26.02.0-0m1892.1; do
	package=${pair%%=*}
	version=${pair#*=}
	[ "$(chroot "$root" dpkg-query -W -f='${Version}' "$package")" = "$version" ] ||
		fail "installed-version:$package"
done
umount "$root/dev" "$root/sys" "$root/proc"
mounted=no
find "$stage" -depth -delete
for link in \
	/etc/systemd/system/multi-user.target.wants/grub-common.service \
	/etc/systemd/system/suspend.target.wants/grub-common.service \
	/etc/systemd/system/hibernate.target.wants/grub-common.service \
	/etc/systemd/system/hybrid-sleep.target.wants/grub-common.service \
	/etc/systemd/system/suspend-then-hibernate.target.wants/grub-common.service; do
	[ ! -L "$root$link" ] || rm "$root$link"
done
find "$root/var/log/apt" -type f -exec sh -c ': >"$1"' sh {} \; 2>/dev/null || true
: >"$root/var/log/dpkg.log"
find "$root/var/cache/ldconfig" -maxdepth 1 -type f -name aux-cache -delete 2>/dev/null || true
find "$root" -xdev -exec touch -h -d "@$source_date_epoch" {} +

artifact=$output_dir/$artifact_name
tar --format=gnu --sort=name --mtime="@$source_date_epoch" --numeric-owner \
	-C "$root" -cf "$artifact" .
sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
printf '%s  %s\n' "$sha" "$artifact_name" >"$artifact.sha256"
cat >"$output_dir/build.env" <<EOF
stage=stage6-daily-oem-rootfs-derivative
base_sha256=$base_sha
plasma_settings_sha256=$(awk 'NR == 1 { print $1 }' "$plasma_settings_input/SHA256SUMS")
calamares_manifest_sha256=$calamares_manifest_sha
source_date_epoch=$source_date_epoch
artifact_size=$bytes
artifact_sha256=$sha
result=pass
EOF
cp "$work/dpkg.log" "$output_dir/dpkg.log"
completed=yes
echo "artifact_sha256=$sha"
echo M1892_STAGE6_OEM_DERIVE_PASS
