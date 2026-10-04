#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
upstream_tar=${2:-}
debian_tar=${3:-}
output_dir=${4:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
patch_file=$tree_dir/patches/plasma-settings-26.02-qt68.patch
upstream_sha=fa7389a121bde75344caf6eba18964eaab4e21a556be6cb390588e5f986140de
debian_sha=339249e093b7ba63d5c0589d6a9b580d0435773f99df82a045c1f65d91d84872
package_version=26.02.0-0m1892.1
source_date_epoch=1788739200

fail() { echo "M1892_PLASMA_SETTINGS_BUILD_FAIL: $*" >&2; exit 1; }
[ -f "$base" ] && [ -f "$upstream_tar" ] && [ -f "$debian_tar" ] &&
	[ -f "$patch_file" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_STAGE6_TAR UPSTREAM_26.02_TAR DEBIAN_25.02_PACKAGING_TAR ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output_dir" ] || fail output-exists
[ -f "$base.sha256" ] || fail base-sidecar-absent
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256" >/dev/null) ||
	fail base-sidecar
[ "$(sha256sum "$upstream_tar" | awk '{print $1}')" = "$upstream_sha" ] ||
	fail upstream-hash
[ "$(sha256sum "$debian_tar" | awk '{print $1}')" = "$debian_sha" ] ||
	fail debian-packaging-hash
for command in aarch64-linux-gnu-readelf chroot cmp cp dpkg-deb file find mkdir \
	mktemp mount sha256sum tar umount; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ "$(id -u)" = 0 ] || fail requires-root-build-environment

work=$(mktemp -d /tmp/m1892-plasma-settings-build.XXXXXXXX)
partial=$output_dir.partial.$$
root=$work/root
mounted=no
cleanup()
{
	if [ "$mounted" = yes ]; then
		umount -l "$root/dev" "$root/sys" "$root/proc" 2>/dev/null || true
	fi
	find "$work" -depth -delete 2>/dev/null || true
	[ ! -e "$partial" ] || find "$partial" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$root/dev" "$root/proc" "$root/sys" "$root/build/input" "$partial"
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
cp --remove-destination /etc/resolv.conf "$root/etc/resolv.conf"
cp "$upstream_tar" "$root/build/input/upstream.tar.xz"
cp "$debian_tar" "$root/build/input/debian.tar.xz"
cp "$patch_file" "$root/build/input/qt68.patch"

mount --bind /proc "$root/proc"
mount --bind /sys "$root/sys"
mount --bind /dev "$root/dev"
mounted=yes
env -u LD_PRELOAD -u FAKEROOTKEY chroot "$root" /bin/bash -lc '
set -euo pipefail
DEBIAN_FRONTEND=noninteractive apt-get -qq -o APT::Sandbox::User=root update
if ! DEBIAN_FRONTEND=noninteractive apt-get -qq -o APT::Sandbox::User=root install -y --no-install-recommends \
  build-essential cmake debhelper dh-sequence-kf6 dh-sequence-qmldeps \
  dpkg-dev extra-cmake-modules fakeroot kirigami-addons-dev \
  libkf6config-dev libkf6coreaddons-dev libkf6crash-dev libkf6dbusaddons-dev \
  libkf6i18n-dev libkf6itemmodels-dev libkf6itemviews-dev libkf6kcmutils-dev \
  libkf6service-dev ninja-build patch pkg-kde-tools pkgconf qt6-base-dev \
  qt6-declarative-dev >/build/apt-install.log 2>&1; then
  tail -n 120 /build/apt-install.log >&2
  exit 1
fi
for variant in accepted-a accepted-b; do
  source_dir=/build/$variant/plasma-settings-26.02.0
  mkdir -p "$source_dir/debian/patches"
  tar -xJf /build/input/upstream.tar.xz --strip-components=1 -C "$source_dir"
  tar -xJf /build/input/debian.tar.xz -C "$source_dir"
  cp /build/input/qt68.patch "$source_dir/debian/patches/qt68.patch"
  printf "%s\n" qt68.patch >"$source_dir/debian/patches/series"
  old_changelog=$source_dir/debian/changelog
  {
    printf "plasma-settings (26.02.0-0m1892.1) trixie; urgency=medium\n\n"
    printf "  * Backport upstream 26.02 navigation stack to Debian 13.\n"
    printf "  * Accept Qt 6.8 QML list syntax.\n\n"
    printf " -- M1892 Mainline Project <noreply@localhost>  Mon, 07 Sep 2026 00:00:00 +0000\n\n"
    cat "$old_changelog"
  } >"$old_changelog.new"
  mv "$old_changelog.new" "$old_changelog"
  sed -i \
    -e "s/2021-2024 Devin Lin/2021-2025 Devin Lin/" \
    -e "s#Files: src/qml/KCMContainer.qml#Files: src/qml/KCMContainer.qml\n       src/qml/KCMPageContainer.qml\n       src/qml/components/*#" \
    "$source_dir/debian/copyright"
  cd "$source_dir"
  export SOURCE_DATE_EPOCH=1788739200
  export DEB_BUILD_OPTIONS="nocheck parallel=8"
  export DEB_BUILD_MAINT_OPTIONS="hardening=+all reproducible=+fixfilepath"
  export CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=/build/$variant=/usr/src/m1892"
  export CXXFLAGS="$CFLAGS"
  export LDFLAGS="-Wl,--build-id=sha1"
  dpkg-buildpackage -b -us -uc >/build/$variant-build.log 2>&1
done
cmp \
  /build/accepted-a/plasma-settings_26.02.0-0m1892.1_arm64.deb \
  /build/accepted-b/plasma-settings_26.02.0-0m1892.1_arm64.deb
gcc -dumpmachine >/build/compiler-machine
gcc -dumpfullversion >/build/compiler-version
dpkg-query -W -f="\${binary:Package}\t\${Version}\t\${Architecture}\n" \
  cmake debhelper dh-sequence-kf6 dh-sequence-qmldeps dpkg-dev \
  extra-cmake-modules kirigami-addons-dev libkf6kcmutils-dev \
  pkg-kde-tools qt6-base-dev qt6-declarative-dev | LC_ALL=C sort \
  >/build/build-packages.tsv
'
umount "$root/dev" "$root/sys" "$root/proc"
mounted=no

deb=$root/build/accepted-a/plasma-settings_${package_version}_arm64.deb
[ -f "$deb" ] || fail output-deb-absent
[ "$(dpkg-deb -f "$deb" Package)" = plasma-settings ] || fail output-package
[ "$(dpkg-deb -f "$deb" Version)" = "$package_version" ] || fail output-version
[ "$(dpkg-deb -f "$deb" Architecture)" = arm64 ] || fail output-architecture
dpkg-deb -c "$deb" >"$work/deb-contents.txt"
grep -Fq './usr/bin/plasma-settings' "$work/deb-contents.txt" || fail output-binary-absent
mkdir -p "$partial"
cp "$deb" "$partial/"
cp "$root/build/build-packages.tsv" "$partial/build-packages.tsv"
cp "$root/build/accepted-a-build.log" "$partial/build-a.log"
cp "$root/build/accepted-b-build.log" "$partial/build-b.log"
sha=$(sha256sum "$deb" | awk '{print $1}')
mkdir -p "$work/deb-root"
dpkg-deb -x "$deb" "$work/deb-root"
binary_needed=$(aarch64-linux-gnu-readelf -d "$work/deb-root/usr/bin/plasma-settings" |
	sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort | tr '\n' ',')
cat >"$partial/BUILD-METADATA.txt" <<EOF
component=m1892-debian13-plasma-settings
package=plasma-settings
version=$package_version
architecture=arm64
upstream_version=26.02.0
upstream_sha256=$upstream_sha
debian_packaging_version=25.02.0-2
debian_packaging_sha256=$debian_sha
qt68_patch_sha256=$(sha256sum "$patch_file" | awk '{print $1}')
base_rootfs_sha256=$(awk 'NR == 1 { print $1 }' "$base.sha256")
source_date_epoch=$source_date_epoch
compiler=$(cat "$root/build/compiler-machine")-gcc-$(cat "$root/build/compiler-version")
binary_needed=$binary_needed
deb_sha256=$sha
reproducible_local_ab=yes
result=pass
EOF
printf '%s  %s\n' "$sha" "$(basename "$deb")" >"$partial/SHA256SUMS"
mv "$partial" "$output_dir"
echo "deb_sha256=$sha"
echo M1892_PLASMA_SETTINGS_BUILD_PASS
