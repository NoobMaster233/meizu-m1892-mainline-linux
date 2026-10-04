#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

output=${1:-}
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.18
source_dir=${M1892_RUNTIME_APK_DIR:-}
fail() { echo "M1892_RUNTIME_APK_DOWNLOAD_FAIL: $*" >&2; exit 1; }
[ -n "$output" ] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
[ ! -e "$output" ] || fail output-exists
for command in awk cp mkdir mv sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ -z "$source_dir" ] || [ -d "$source_dir" ] || fail local-source-not-directory
[ -n "$source_dir" ] || command -v curl >/dev/null 2>&1 || fail missing-command:curl
mkdir -p "$output"

fetch()
{
	expected=$1
	name=$2
	partial=$output/$name.partial
	final=$output/$name
	if [ -n "$source_dir" ]; then
		[ -f "$source_dir/$name" ] || fail "local-source-missing:$name"
		cp "$source_dir/$name" "$partial"
	else
		curl -fL --retry 3 --output "$partial" "$release/$name"
	fi
	actual=$(sha256sum "$partial" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "sha256:$name:$actual"
	mv "$partial" "$final"
	printf '%s  %s\n' "$expected" "$name" >>"$output/SHA256SUMS"
}

fetch a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4 \
	rmtfs-1.3-r0.apk
fetch 5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769 \
	rmtfs-openrc-1.3-r0.apk
fetch 09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7 \
	rmtfs-udev-1.3-r0.apk
fetch 05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b \
	m1892-telephony-apks.tar.gz
fetch ee1d5d17f6e05322f299e190cd40b63bdf29193052c90ccdeddfb829ced8177d \
	stevia-0.57.0-r1.apk
fetch 6304118d6a3177324102070f1bdb1c8cc9be68e8f20c2e211ee408315722065d \
	stevia-schemas-0.57.0-r1.apk
(cd "$output" && sha256sum -c SHA256SUMS)
echo "output=$output"
[ -z "$source_dir" ] || echo "source=local-hash-verified"
echo M1892_RUNTIME_APK_DOWNLOAD_PASS
