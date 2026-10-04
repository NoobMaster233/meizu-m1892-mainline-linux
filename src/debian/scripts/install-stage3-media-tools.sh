#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

mode=install
if [ "$1" = --check ]; then
	mode=check
	root=
	debs=$2
else
	root=$1
	debs=$2
fi
fail() { echo "M1892_MEDIA_TOOLS_FAIL: $*" >&2; exit 1; }
[ -d "$debs" ] || fail invalid-input
[ "$mode" = check ] || [ -d "$root" ] || fail invalid-root
for command in awk chroot cp dpkg-deb find mkdir sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

check()
{
	file=$1
	expected_hash=$2
	expected_package=$3
	expected_version=$4
	path=$debs/$file
	[ -f "$path" ] || fail "missing:$file"
	[ "$(sha256sum "$path" | awk '{print $1}')" = "$expected_hash" ] || fail "hash:$file"
	[ "$(dpkg-deb -f "$path" Package)" = "$expected_package" ] || fail "package:$file"
	[ "$(dpkg-deb -f "$path" Version)" = "$expected_version" ] || fail "version:$file"
	[ "$(dpkg-deb -f "$path" Architecture)" = arm64 ] || fail "architecture:$file"
}

check gstreamer1.0-tools_1.26.2-2_arm64.deb 7cd6fe07960b9132dc3b4adfee62ebc074e9213acc157995f68e5aab9f760ad7 gstreamer1.0-tools 1.26.2-2
check libv4l-0t64_1.30.1-1_arm64.deb 0daab812f42d309969a867230d2ec9b6ad2127bf884bf8f208e5035e5defef5a libv4l-0t64 1.30.1-1
check libv4l2rds0t64_1.30.1-1_arm64.deb 0fbb9db89930e81b436f64c08c3d8ff294da31b9af4b921321ec753fe243529e libv4l2rds0t64 1.30.1-1
check libv4lconvert0t64_1.30.1-1_arm64.deb b7e56d6e148ef9dcff8074b953ed4c3f3c4014ee63a6bbc5d3e72c4d84697151 libv4lconvert0t64 1.30.1-1
check v4l-utils_1.30.1-1_arm64.deb 4a7764f697fd976c5d5939fd48189ff612fc8bc97d3630646c5cf24bd0da8466 v4l-utils 1.30.1-1

[ "$mode" = install ] || { echo M1892_MEDIA_TOOLS_CHECK_PASS; exit 0; }

stage=$root/run/m1892-media-tools
mkdir -p "$stage"
for file in gstreamer1.0-tools_1.26.2-2_arm64.deb \
	libv4l-0t64_1.30.1-1_arm64.deb \
	libv4l2rds0t64_1.30.1-1_arm64.deb \
	libv4lconvert0t64_1.30.1-1_arm64.deb \
	v4l-utils_1.30.1-1_arm64.deb; do
	cp "$debs/$file" "$stage/$file"
done
chroot "$root" dpkg -i \
	/run/m1892-media-tools/libv4l2rds0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/libv4lconvert0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/libv4l-0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/v4l-utils_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/gstreamer1.0-tools_1.26.2-2_arm64.deb
find "$stage" -depth -delete
echo M1892_MEDIA_TOOLS_INSTALL_PASS
