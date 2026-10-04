#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

mode=install
if [ "${1:-}" = --check ]; then
	mode=check
	root=
	input=${2:-}
else
	root=${1:-}
	input=${2:-}
fi
package=plasma-settings_26.02.0-0m1892.1_arm64.deb
expected_version=26.02.0-0m1892.1
expected_hash=edc1fb29963af5a90ba111e3cdea35f034ac7abd41521dec8bcad2e9483087a7
fail() { echo "M1892_PLASMA_SETTINGS_INSTALL_FAIL: $*" >&2; exit 1; }
[ -d "$input" ] || fail input-directory
[ "$mode" = check ] || [ -d "$root" ] || fail root-directory
for command in awk chroot cp dpkg-deb find mkdir sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ -f "$input/$package" ] && [ -f "$input/SHA256SUMS" ] &&
	[ -f "$input/BUILD-METADATA.txt" ] || fail input-contract
(cd "$input" && sha256sum -c SHA256SUMS >/dev/null) || fail package-hash
[ "$(sha256sum "$input/$package" | awk '{print $1}')" = "$expected_hash" ] ||
	fail accepted-package-hash
[ "$(dpkg-deb -f "$input/$package" Package)" = plasma-settings ] || fail package-name
[ "$(dpkg-deb -f "$input/$package" Version)" = "$expected_version" ] || fail package-version
[ "$(dpkg-deb -f "$input/$package" Architecture)" = arm64 ] || fail package-architecture
grep -Fxq 'component=m1892-debian13-plasma-settings' "$input/BUILD-METADATA.txt" ||
	fail metadata-component
grep -Fxq "version=$expected_version" "$input/BUILD-METADATA.txt" || fail metadata-version
grep -Fxq "deb_sha256=$expected_hash" "$input/BUILD-METADATA.txt" || fail metadata-deb-hash
grep -Fxq 'upstream_sha256=fa7389a121bde75344caf6eba18964eaab4e21a556be6cb390588e5f986140de' \
	"$input/BUILD-METADATA.txt" || fail metadata-upstream-hash
grep -Fxq 'debian_packaging_sha256=339249e093b7ba63d5c0589d6a9b580d0435773f99df82a045c1f65d91d84872' \
	"$input/BUILD-METADATA.txt" || fail metadata-debian-packaging-hash
grep -Fxq 'qt68_patch_sha256=5325fa08a0fd72c2b7688c082fca0bb68b227c1d1000db4df73835ec8acf8645' \
	"$input/BUILD-METADATA.txt" || fail metadata-patch-hash
grep -Fxq 'reproducible_local_ab=yes' "$input/BUILD-METADATA.txt" || fail metadata-reproducible
grep -Fxq 'result=pass' "$input/BUILD-METADATA.txt" || fail metadata-result
[ "$mode" = install ] || { echo M1892_PLASMA_SETTINGS_CHECK_PASS; exit 0; }

stage=$root/run/m1892-plasma-settings
mkdir -p "$stage"
cp "$input/$package" "$stage/$package"
DEBIAN_FRONTEND=noninteractive chroot "$root" dpkg -i "/run/m1892-plasma-settings/$package"
chroot "$root" dpkg-query -W -f='${Version}\n' plasma-settings |
	grep -Fxq "$expected_version" || fail installed-version
find "$stage" -depth -delete
echo M1892_PLASMA_SETTINGS_INSTALL_PASS
