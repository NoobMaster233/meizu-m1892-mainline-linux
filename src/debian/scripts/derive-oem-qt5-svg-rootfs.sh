#!/bin/sh
# SPDX-License-Identifier: MIT
# Offline official-package derivative of the accepted, owner-neutral OEM base.
set -eu
base=${1:-} deb=${2:-} output=${3:-}
fail() { echo "M1892_OEM_SVG_DERIVE_FAIL: $*" >&2; exit 1; }
for command in chroot dpkg-deb grep id install mktemp mount sha256sum tar umount; do command -v "$command" >/dev/null || fail "command:$command"; done
[ "$(id -u)" = 0 ] || fail run-in-root-mount-namespace
[ -f "$base" ] && [ -f "$deb" ] || fail inputs
case "$output" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output" ] || fail output-exists
[ "$(sha256sum "$base" | awk '{print $1}')" = f1bbd88538e840b3d4d9b04a0af2815c5bcac7d67bed536bad33b11b4096f6ef ] || fail accepted-base
[ "$(sha256sum "$deb" | awk '{print $1}')" = 1608a3d0dd0435269794eae57fd608a17fdc6dc282330e5248ba60ce64153441 ] || fail official-deb
[ "$(dpkg-deb -f "$deb" Package)" = libqt5svg5 ] &&
 [ "$(dpkg-deb -f "$deb" Version)" = 5.15.15-2 ] &&
 [ "$(dpkg-deb -f "$deb" Architecture)" = arm64 ] || fail package-contract
work=$(mktemp -d /tmp/m1892-oem-svg-derive.XXXXXXXX)
root=$work/root
mounted=no
cleanup() { if [ "$mounted" = yes ]; then umount "$root/dev" 2>/dev/null || true; fi; find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
install -d "$root" "$output"
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
install -d "$root/dev" "$root/run/m1892-offline-debs"
mount --bind /dev "$root/dev"; mounted=yes
install -m 0644 "$deb" "$root/run/m1892-offline-debs/libqt5svg5.deb"
DEBIAN_FRONTEND=noninteractive chroot "$root" dpkg -i /run/m1892-offline-debs/libqt5svg5.deb
chroot "$root" dpkg-query -W -f='${db:Status-Abbrev}\n' libqt5svg5 | grep -Fxq 'ii ' || fail installed-state
[ -f "$root/usr/lib/aarch64-linux-gnu/qt5/plugins/imageformats/libqsvg.so" ] || fail plugin
umount "$root/dev"; mounted=no
find "$root/run/m1892-offline-debs" -depth -delete
for backup in shadow- gshadow- passwd- group-; do rm -f "$root/etc/$backup"; done
: >"$root/var/log/dpkg.log"
find "$root/var/cache/ldconfig" -maxdepth 1 -type f -name aux-cache -delete 2>/dev/null || true
artifact=$output/m1892-debian13-plasma-mobile-stage6-oem-arm64.tar
tar --format=gnu --sort=name --mtime='@1788739200' --numeric-owner -C "$root" -cf "$artifact" .
sha=$(sha256sum "$artifact" | awk '{print $1}')
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
printf 'stage=offline-oem-qt5-svg-derivative\nbase_sha256=f1bbd88538e840b3d4d9b04a0af2815c5bcac7d67bed536bad33b11b4096f6ef\nlibqt5svg5_sha256=1608a3d0dd0435269794eae57fd608a17fdc6dc282330e5248ba60ce64153441\nartifact_sha256=%s\nresult=pass\n' "$sha" >"$output/build.env"
chmod 0644 "$artifact" "$artifact.sha256" "$output/build.env"
echo M1892_OEM_SVG_DERIVE_PASS
