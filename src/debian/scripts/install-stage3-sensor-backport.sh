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
fail() { echo "M1892_SENSOR_BACKPORT_FAIL: $*" >&2; exit 1; }
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

# Pinned Debian arm64 packages; no forky repository remains enabled at runtime.
check libprotobuf-c1_1.5.1-1_arm64.deb 6c34790825abb19889f351938430a1e3a4f263cc55812e00f1ba01399638b94b libprotobuf-c1 1.5.1-1
check libssc2_0.4.4-1_arm64.deb ee8284c0101d1e52b93c47873b1fcf1dbc97c7596c6eadabbb202e422aa859cb libssc2 0.4.4-1
check libssc-bin_0.4.4-1_arm64.deb ffe7f2b0c3cdd231177576955868025b9d3ed677232523b9e6cd4e0b8de6fdce libssc-bin 0.4.4-1
check iio-sensor-proxy_3.9-1_arm64.deb a72d111ca58c22dd7f2b71ed20001425fc180a5581df8c07c0420aaaeba61415 iio-sensor-proxy 3.9-1

[ "$mode" = install ] || { echo M1892_SENSOR_BACKPORT_CHECK_PASS; exit 0; }

stage=$root/run/m1892-sensor-backport
mkdir -p "$stage"
for file in libprotobuf-c1_1.5.1-1_arm64.deb libssc2_0.4.4-1_arm64.deb libssc-bin_0.4.4-1_arm64.deb iio-sensor-proxy_3.9-1_arm64.deb; do
  cp "$debs/$file" "$stage/$file"
done
chroot "$root" dpkg -i /run/m1892-sensor-backport/libprotobuf-c1_1.5.1-1_arm64.deb /run/m1892-sensor-backport/libssc2_0.4.4-1_arm64.deb /run/m1892-sensor-backport/libssc-bin_0.4.4-1_arm64.deb /run/m1892-sensor-backport/iio-sensor-proxy_3.9-1_arm64.deb
find "$stage" -depth -delete
echo M1892_SENSOR_BACKPORT_INSTALL_PASS
