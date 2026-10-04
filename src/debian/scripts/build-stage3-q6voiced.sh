#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
debs=${2:-}
output_dir=${3:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
source_file=$tree_dir/../public-release/src/runtime-inputs/m1892-userspace/q6voiced/q6voiced-m1892.c
[ -f "$base" ] && [ -d "$debs" ] && [ -f "$source_file" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_STAGE3_TAR DEV_DEBS ABSOLUTE_OUTPUT_DIRECTORY" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_Q6VOICED_BUILD_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ ! -e "$output_dir" ] || { echo 'M1892_Q6VOICED_BUILD_FAIL: output-exists' >&2; exit 1; }
[ -f "$base.sha256" ] || { echo 'M1892_Q6VOICED_BUILD_FAIL: base-sidecar' >&2; exit 1; }
(cd "$(dirname "$base")" && sha256sum -c "$(basename "$base").sha256") >/dev/null || {
	echo 'M1892_Q6VOICED_BUILD_FAIL: base-hash' >&2
	exit 1
}
for command in aarch64-linux-gnu-gcc aarch64-linux-gnu-readelf \
	aarch64-linux-gnu-strip dpkg-deb file find mkdir mktemp sha256sum tar; do
	command -v "$command" >/dev/null || {
		echo "M1892_Q6VOICED_BUILD_FAIL: missing-command:$command" >&2
		exit 1
	}
done

check_deb()
{
	file=$1
	hash=$2
	package=$3
	version=$4
	architecture=$5
	path=$debs/$file
	[ -f "$path" ] && [ "$(sha256sum "$path" | awk '{print $1}')" = "$hash" ] &&
		[ "$(dpkg-deb -f "$path" Package)" = "$package" ] &&
		[ "$(dpkg-deb -f "$path" Version)" = "$version" ] &&
		[ "$(dpkg-deb -f "$path" Architecture)" = "$architecture" ] || {
		echo "M1892_Q6VOICED_BUILD_FAIL: dev-deb:$file" >&2
		exit 1
	}
}
check_deb libasound2-dev_1.2.14-1_arm64.deb \
	4220e6de896894c670227210fd1c500bb05c8e824304418b900183619e68942f \
	libasound2-dev 1.2.14-1 arm64
check_deb libdbus-1-dev_1.16.2-2_arm64.deb \
	305788b468ae2daba9074e59906a26df34d3f6f347d3191f13043f5a9224f90b \
	libdbus-1-dev 1.16.2-2 arm64
check_deb libc6-dev_2.41-12+deb13u3_arm64.deb \
	b2d2660900bd0bfe110b485532367774589d86d2e57b4ed74d8f06e3208a6959 \
	libc6-dev 2.41-12+deb13u3 arm64
check_deb linux-libc-dev_6.12.94-1_all.deb \
	6183985d8fa4b97d277e8b55b10ad247bd98bc23aa8b531c1f79f05bfbf50997 \
	linux-libc-dev 6.12.94-1 all
[ "$(sha256sum "$source_file" | awk '{print $1}')" = \
	2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4 ] || {
	echo 'M1892_Q6VOICED_BUILD_FAIL: source-hash' >&2
	exit 1
}

work=$(mktemp -d /tmp/m1892-q6voiced-build.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
sysroot=$work/sysroot
mkdir -p "$sysroot" "$output_dir"
for file in "$debs"/*.deb; do dpkg-deb -x "$file" "$sysroot"; done
tar --no-same-owner -xf "$base" -C "$sysroot" \
	./lib \
	./usr/lib/ld-linux-aarch64.so.1 \
	./usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1 \
	./usr/lib/aarch64-linux-gnu/libasound.so.2 \
	./usr/lib/aarch64-linux-gnu/libasound.so.2.0.0 \
	./usr/lib/aarch64-linux-gnu/libdbus-1.so.3 \
	./usr/lib/aarch64-linux-gnu/libdbus-1.so.3.38.3 \
	./usr/lib/aarch64-linux-gnu/libc.so.6 \
	./usr/lib/aarch64-linux-gnu/libm.so.6 \
	./usr/lib/aarch64-linux-gnu/libmvec.so.1

binary=$output_dir/q6voiced
aarch64-linux-gnu-gcc --sysroot="$sysroot" -O2 -pipe -fno-ident \
	-ffile-prefix-map="$tree_dir"=/usr/src/m1892 \
	-I=/usr/include/dbus-1.0 \
	-I=/usr/lib/aarch64-linux-gnu/dbus-1.0/include \
	-L"$sysroot/usr/lib/aarch64-linux-gnu" \
	-Wl,-rpath-link,"$sysroot/usr/lib/aarch64-linux-gnu" \
	-Wl,--build-id=none -Wl,--as-needed -Wl,--allow-shlib-undefined \
	-o "$binary" "$source_file" -lasound -ldbus-1
aarch64-linux-gnu-strip "$binary"
[ "$(file -b "$binary")" = \
	'ELF 64-bit LSB pie executable, ARM aarch64, version 1 (SYSV), dynamically linked, interpreter /lib/ld-linux-aarch64.so.1, for GNU/Linux 3.7.0, stripped' ] || {
	echo 'M1892_Q6VOICED_BUILD_FAIL: output-elf' >&2
	exit 1
}
needed=$(aarch64-linux-gnu-readelf -d "$binary" |
	sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort | tr '\n' ',')
[ "$needed" = 'ld-linux-aarch64.so.1,libasound.so.2,libc.so.6,libdbus-1.so.3,' ] || {
	echo "M1892_Q6VOICED_BUILD_FAIL: needed:$needed" >&2
	exit 1
}
sha=$(sha256sum "$binary" | awk '{print $1}')
cat >"$output_dir/BUILD-METADATA.txt" <<EOF
component=m1892-debian13-q6voiced
source_sha256=2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4
base_rootfs_sha256=$(awk 'NR == 1 { print $1 }' "$base.sha256")
compiler=$(aarch64-linux-gnu-gcc -dumpmachine)-gcc-$(aarch64-linux-gnu-gcc -dumpfullversion)
binary_sha256=$sha
needed=$needed
result=pass
EOF
printf '%s  q6voiced\n' "$sha" >"$output_dir/SHA256SUMS"
echo "binary_sha256=$sha"
echo M1892_Q6VOICED_BUILD_PASS
