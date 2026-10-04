#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
upstream_tar=${2:-}
debian_tar=${3:-}
output_dir=${4:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
patch_file=$tree_dir/../public-release/src/runtime-inputs/userspace/telephony/callaudiod-pulse17-split-profile.patch
[ -f "$base" ] && [ -f "$upstream_tar" ] && [ -f "$debian_tar" ] &&
	[ -f "$patch_file" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_PHONE_TAR UPSTREAM_TAR DEBIAN_TAR ABSOLUTE_OUTPUT_DIRECTORY" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_CALLAUDIOD_BUILD_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ ! -e "$output_dir" ] || { echo 'M1892_CALLAUDIOD_BUILD_FAIL: output-exists' >&2; exit 1; }
[ -f "$base.sha256" ] || { echo 'M1892_CALLAUDIOD_BUILD_FAIL: base-sidecar' >&2; exit 1; }
(cd "$(dirname "$base")" && sha256sum -c "$(basename "$base").sha256") >/dev/null || {
	echo 'M1892_CALLAUDIOD_BUILD_FAIL: base-hash' >&2
	exit 1
}
[ "$(sha256sum "$upstream_tar" | awk '{print $1}')" = \
	17070205024a4bb75016dad3cc132039dff28d9f3a40226eb283ae3a78ce0ecf ] || {
	echo 'M1892_CALLAUDIOD_BUILD_FAIL: upstream-hash' >&2
	exit 1
}
[ "$(sha256sum "$debian_tar" | awk '{print $1}')" = \
	6016f4520225e058c9e0d2b7284297155ab8c07ab4df5423be00e9e7fb0d64ae ] || {
	echo 'M1892_CALLAUDIOD_BUILD_FAIL: debian-hash' >&2
	exit 1
}
[ "$(sha256sum "$patch_file" | awk '{print $1}')" = \
	ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e ] || {
	echo 'M1892_CALLAUDIOD_BUILD_FAIL: m1892-patch-hash' >&2
	exit 1
}
for command in aarch64-linux-gnu-readelf cp find file mkdir mktemp sha256sum tar unshare; do
	command -v "$command" >/dev/null || {
		echo "M1892_CALLAUDIOD_BUILD_FAIL: missing-command:$command" >&2
		exit 1
	}
done

work=$(mktemp -d /tmp/m1892-callaudiod-build.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output_dir"
tar --no-same-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev" "$root/build"
cp --remove-destination /etc/resolv.conf "$root/etc/resolv.conf"
tar -xf "$upstream_tar" -C "$root/build"
tar -xf "$debian_tar" -C "$root/build/callaudiod-0.1.10"
cp "$patch_file" "$root/build/m1892.patch"

env -u LD_PRELOAD -u FAKEROOTKEY \
	unshare --map-root-user --mount --pid --fork --mount-proc=/proc --root="$root" \
	/bin/bash -lc '
set -e
apt-get -qq -o APT::Sandbox::User=root update
DEBIAN_FRONTEND=noninteractive apt-get -qq -o APT::Sandbox::User=root install -y --no-install-recommends \
  build-essential meson ninja-build pkgconf libasound2-dev libglib2.0-dev libpulse-dev patch
cd /build/callaudiod-0.1.10
patch -p1 < /build/m1892.patch
export CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=/build=/usr/src/m1892"
export LDFLAGS="-Wl,--build-id=none"
for variant in accepted-a accepted-b; do
  meson setup "/build/$variant" . --buildtype=release --prefix=/usr >/dev/null
  meson compile -C "/build/$variant" callaudiod >/dev/null
  strip "/build/$variant/src/callaudiod"
done
cmp /build/accepted-a/src/callaudiod /build/accepted-b/src/callaudiod
gcc -dumpmachine > /build/compiler-machine
gcc -dumpfullversion > /build/compiler-version
dpkg-query -W -f="\${binary:Package}\t\${Version}\t\${Architecture}\n" \
  build-essential meson ninja-build pkgconf libasound2-dev libglib2.0-dev libpulse-dev patch \
  | LC_ALL=C sort > /build/build-packages.tsv
'

binary=$output_dir/callaudiod
cp "$root/build/accepted-a/src/callaudiod" "$binary"
chmod 0755 "$binary"
case $(file -b "$binary") in
	'ELF 64-bit LSB pie executable, ARM aarch64,'*', dynamically linked, interpreter /lib/ld-linux-aarch64.so.1,'*', stripped') ;;
	*) echo 'M1892_CALLAUDIOD_BUILD_FAIL: output-elf' >&2; exit 1 ;;
esac
needed=$(aarch64-linux-gnu-readelf -d "$binary" |
	sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort | tr '\n' ',')
expected_needed='libc.so.6,libgio-2.0.so.0,libglib-2.0.so.0,libgobject-2.0.so.0,libpulse-mainloop-glib.so.0,libpulse.so.0,'
[ "$needed" = "$expected_needed" ] || {
	echo "M1892_CALLAUDIOD_BUILD_FAIL: needed:$needed" >&2
	exit 1
}
sha=$(sha256sum "$binary" | awk '{print $1}')
cp "$root/build/build-packages.tsv" "$output_dir/build-packages.tsv"
cat >"$output_dir/BUILD-METADATA.txt" <<EOF
component=m1892-debian13-callaudiod
upstream_sha256=17070205024a4bb75016dad3cc132039dff28d9f3a40226eb283ae3a78ce0ecf
debian_patchset_sha256=6016f4520225e058c9e0d2b7284297155ab8c07ab4df5423be00e9e7fb0d64ae
m1892_patch_sha256=ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e
base_rootfs_sha256=$(awk 'NR == 1 { print $1 }' "$base.sha256")
compiler=$(cat "$root/build/compiler-machine")-gcc-$(cat "$root/build/compiler-version")
binary_sha256=$sha
needed=$needed
reproducible_local_ab=yes
result=pass
EOF
printf '%s  callaudiod\n' "$sha" >"$output_dir/SHA256SUMS"
echo "binary_sha256=$sha"
echo M1892_CALLAUDIOD_BUILD_PASS
