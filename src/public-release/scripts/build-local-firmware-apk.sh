#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

archive=${1:-}
output=${2:-}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
apkbuild=$script_dir/../src/pmaports/firmware-meizu-m1892/APKBUILD
expected_archive_sha512=474dbb8e25e8e38f9e1880b5310e830c51a71732bdcf0264b31b1bac092173ab5eea3f2ad599900e2bef1d5f73a04c456c36521edfdce5fd5c2cca670f0dd3dd
fail() { echo "M1892_LOCAL_FIRMWARE_APK_FAIL: $*" >&2; exit 1; }
[ -f "$archive" ] && [ -n "$output" ] || {
	echo "usage: $0 FIRMWARE_RUNTIME_ARCHIVE NEW_OUTPUT.apk" >&2
	exit 2
}
[ -f "$apkbuild" ] || fail missing-apkbuild
[ ! -e "$output" ] || fail output-exists
[ "$(id -u)" -ne 0 ] || fail run-as-regular-user-not-root
for command in abuild abuild-keygen awk basename dirname find id install mkdir \
	mktemp sha256sum sha512sum tar; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ "$(sha512sum "$archive" | awk '{print $1}')" = "$expected_archive_sha512" ] ||
	fail firmware-runtime-archive-hash

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-local-firmware-apk.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
install -m 0644 "$apkbuild" "$work/APKBUILD"
install -m 0644 "$archive" "$work/$(basename -- "$archive")"

key_count=$(find "${HOME:?}/.abuild" -maxdepth 1 -type f -name '*.rsa' 2>/dev/null |
	awk 'END {print NR+0}')
if [ "$key_count" -eq 0 ]; then
	mkdir -p "$HOME/.abuild"
	abuild-keygen -a -n
fi
packager_private_key=$(find "$HOME/.abuild" -maxdepth 1 -type f -name '*.rsa' |
	LC_ALL=C sort | awk 'NR == 1 { print; exit }')
[ -n "$packager_private_key" ] || fail missing-packager-private-key
PACKAGER_PRIVKEY=$packager_private_key
export PACKAGER_PRIVKEY
# This repository contains only the package built in this invocation.  A fresh
# regular-user abuild key is intentionally not installed system-wide, so let
# apk trust that self-generated package while abuild creates its local index.
# The archive hashes, package identity, payload modes, and final image content
# are independently pinned and verified below and by the image maker.
APK='apk --allow-untrusted'
export APK
(cd "$work" && CARCH=aarch64 abuild -d -r -P "$work/packages")
built=$(find "$work/packages" -type f \
	-name 'firmware-meizu-m1892-20260831-r0.apk' -print)
[ "$(printf '%s\n' "$built" | awk 'NF {n++} END {print n+0}')" -eq 1 ] ||
	fail built-apk-count
install -D -m 0644 "$built" "$output"
identity=$(tar -xOf "$output" .PKGINFO 2>/dev/null |
	awk -F ' = ' '
		$1=="pkgname" {name=$2}
		$1=="pkgver" {version=$2}
		$1=="arch" {arch=$2}
		END {print name ":" version ":" arch}
	')
[ "$identity" = firmware-meizu-m1892:20260831-r0:aarch64 ] ||
	fail "package-identity:$identity"
echo "output=$output"
sha256sum "$output"
echo M1892_LOCAL_FIRMWARE_APK_PASS
