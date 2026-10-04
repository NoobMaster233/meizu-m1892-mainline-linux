#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

page=https://www.flyme.com/firmwarelist-175.html
url=https://www.flyme.com/zh/download?key=kca6ebTG
expected_size=2795259474
expected_md5=b71e9023109e16ca1a82548ec3aed851
mode=${1:-}
output=${2:-}
fail() { echo "M1892_FLYME_DOWNLOAD_FAIL: $*" >&2; exit 1; }
for command in awk curl find grep md5sum mkdir mv od stat tr; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

case $mode in
--check)
	work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-flyme-check.XXXXXX")
	cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
	trap cleanup EXIT HUP INT TERM
	curl -L --fail --referer "$page" --range 0-3 \
		--dump-header "$work/headers" --output "$work/prefix" "$url"
	grep -Fiq "content-range: bytes 0-3/$expected_size" "$work/headers" ||
		fail remote-size
	[ "$(od -An -tx1 "$work/prefix" | tr -d ' \n')" = 504b0304 ] ||
		fail remote-zip-prefix
	echo "bytes=$expected_size md5=$expected_md5"
	echo M1892_FLYME_DOWNLOAD_CHECK_PASS
	;;
--download)
	[ -n "$output" ] || fail missing-output
	[ ! -e "$output" ] || fail output-exists
	partial=$output.partial
	mkdir -p "$(dirname -- "$output")"
	curl -L --fail --referer "$page" --continue-at - \
		--output "$partial" "$url"
	[ "$(stat -c %s "$partial")" = "$expected_size" ] || fail downloaded-size
	[ "$(md5sum "$partial" | awk '{print $1}')" = "$expected_md5" ] ||
		fail downloaded-md5
	mv "$partial" "$output"
	echo "output=$output bytes=$expected_size md5=$expected_md5"
	echo M1892_FLYME_DOWNLOAD_PASS
	;;
*)
	echo "usage: $0 --check | --download OUTPUT.zip" >&2
	exit 2
	;;
esac
