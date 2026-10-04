#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
upstream_tar=${2:-}
output_dir=${3:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
patch_file=$tree_dir/patches/spacebar-multi-bearer.patch
upstream_sha=e717cef4a6cf408bffddaf28882da644e37289f158cbf003c9e0329da9c74ab7
upstream_commit=ba754af074303ace6016f6f7732ddf27a474cbec

[ -f "$base" ] && [ -f "$upstream_tar" ] && [ -f "$patch_file" ] &&
	[ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_PHONE_TAR SPACEBAR_UPSTREAM_TAR ABSOLUTE_OUTPUT_DIRECTORY" >&2
	exit 2
}
case "$output_dir" in
	/*) ;;
	*) echo 'M1892_SPACEBAR_BUILD_FAIL: output-not-absolute' >&2; exit 2 ;;
esac
[ ! -e "$output_dir" ] || {
	echo 'M1892_SPACEBAR_BUILD_FAIL: output-exists' >&2
	exit 1
}
output_partial=$output_dir.partial.$$
[ ! -e "$output_partial" ] || {
	echo 'M1892_SPACEBAR_BUILD_FAIL: partial-output-exists' >&2
	exit 1
}
[ -f "$base.sha256" ] || {
	echo 'M1892_SPACEBAR_BUILD_FAIL: base-sidecar' >&2
	exit 1
}
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256") >/dev/null || {
	echo 'M1892_SPACEBAR_BUILD_FAIL: base-hash' >&2
	exit 1
}
[ "$(sha256sum "$upstream_tar" | awk '{print $1}')" = "$upstream_sha" ] || {
	echo 'M1892_SPACEBAR_BUILD_FAIL: upstream-hash' >&2
	exit 1
}
for command in aarch64-linux-gnu-readelf cmake cmp find file mkdir mktemp \
	sha256sum tar unshare; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "M1892_SPACEBAR_BUILD_FAIL: missing-command:$command" >&2
		exit 1
	}
done

work=$(mktemp -d /tmp/m1892-spacebar-build.XXXXXXXX)
cleanup()
{
	find "$work" -depth -delete 2>/dev/null || true
	[ ! -e "$output_partial" ] || find "$output_partial" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output_partial"
tar --no-same-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev" "$root/build/source"
cp --remove-destination /etc/resolv.conf "$root/etc/resolv.conf"
tar -xf "$upstream_tar" -C "$root/build/source" --strip-components=1
cp "$patch_file" "$root/build/spacebar-multi-bearer.patch"

env -u LD_PRELOAD -u FAKEROOTKEY \
	unshare --map-root-user --mount --pid --fork --mount-proc=/proc --root="$root" \
	/bin/bash -lc '
set -e
apt-get -qq -o APT::Sandbox::User=root update
DEBIAN_FRONTEND=noninteractive apt-get -qq -o APT::Sandbox::User=root install -y --no-install-recommends \
  build-essential cmake extra-cmake-modules ninja-build patch pkgconf \
  kirigami-addons-dev kirigami2-dev libc-ares-dev libcurl4-gnutls-dev \
  libfuturesql6-dev libkf6config-dev libkf6contacts-dev libkf6coreaddons-dev \
  libkf6crash-dev libkf6dbusaddons-dev libkf6i18n-dev libkf6kio-dev \
  libkf6modemmanagerqt-dev libkf6notifications-dev libkf6people-dev \
  libkf6windowsystem-dev libkirigami-dev libphonenumber-dev qcoro-qt6-dev \
  qt6-5compat-dev qt6-base-dev qt6-declarative-dev
cd /build/source
patch -p1 < /build/spacebar-multi-bearer.patch
export SOURCE_DATE_EPOCH=1789056000
export CXXFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=/build=/usr/src/m1892"
export LDFLAGS="-Wl,--build-id=none"
for variant in accepted-a accepted-b; do
  cmake -S . -B "/build/$variant" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_TESTING=OFF >/dev/null
  cmake --build "/build/$variant" --target spacebar-daemon --parallel 8 >/dev/null
  strip "/build/$variant/bin/spacebar-daemon"
done
cmp /build/accepted-a/bin/spacebar-daemon /build/accepted-b/bin/spacebar-daemon
gcc -dumpmachine > /build/compiler-machine
gcc -dumpfullversion > /build/compiler-version
dpkg-query -W -f="\${binary:Package}\t\${Version}\t\${Architecture}\n" \
  cmake extra-cmake-modules libkf6modemmanagerqt-dev ninja-build qt6-base-dev \
  | LC_ALL=C sort > /build/build-packages.tsv
'

binary=$output_partial/spacebar-daemon
cp "$root/build/accepted-a/bin/spacebar-daemon" "$binary"
chmod 0755 "$binary"
case $(file -b "$binary") in
	'ELF 64-bit LSB pie executable, ARM aarch64,'*', dynamically linked,'*) ;;
	*) echo 'M1892_SPACEBAR_BUILD_FAIL: output-elf' >&2; exit 1 ;;
esac
needed=$(aarch64-linux-gnu-readelf -d "$binary" |
	sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort | tr '\n' ',')
sha=$(sha256sum "$binary" | awk '{print $1}')
cp "$root/build/build-packages.tsv" "$output_partial/build-packages.tsv"
cat >"$output_partial/BUILD-METADATA.txt" <<EOF
component=m1892-debian13-spacebar-multi-bearer
upstream_commit=$upstream_commit
upstream_sha256=$upstream_sha
patch_sha256=$(sha256sum "$patch_file" | awk '{print $1}')
base_rootfs_sha256=$(awk 'NR == 1 { print $1 }' "$base.sha256")
compiler=$(cat "$root/build/compiler-machine")-gcc-$(cat "$root/build/compiler-version")
binary_sha256=$sha
needed=$needed
reproducible_local_ab=yes
result=pass
EOF
printf '%s  spacebar-daemon\n' "$sha" >"$output_partial/SHA256SUMS"
mv "$output_partial" "$output_dir"
echo "binary_sha256=$sha"
echo M1892_SPACEBAR_BUILD_PASS
