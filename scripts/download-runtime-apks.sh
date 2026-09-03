#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

output=${1:-}
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
fail() { echo "M1892_RUNTIME_APK_DOWNLOAD_FAIL: $*" >&2; exit 1; }
[ -n "$output" ] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
[ ! -e "$output" ] || fail output-exists
for command in awk curl mkdir mv sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
mkdir -p "$output"

fetch()
{
	expected=$1
	name=$2
	partial=$output/$name.partial
	final=$output/$name
	curl -fL --retry 3 --output "$partial" "$release/$name"
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
(cd "$output" && sha256sum -c SHA256SUMS)
echo "output=$output"
echo M1892_RUNTIME_APK_DOWNLOAD_PASS
