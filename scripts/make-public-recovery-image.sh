#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

public_boot=${1:-}
stock_recovery=${2:-}
output=${3:-}
partition_size=67108864
stock_vbmeta_offset=26091520
stock_recovery_sha256=faffac470b6eb984167b48c303177efd9fb20be2b2d5f0402d06a3a49605a997
fail() { echo "M1892_PUBLIC_RECOVERY_FAIL: $*" >&2; exit 1; }

[ -f "$public_boot" ] || fail missing-public-boot
[ -f "$stock_recovery" ] || fail missing-stock-recovery
[ -n "$output" ] || fail missing-output
[ ! -e "$output" ] || fail output-exists
for command in avbtool awk cmp cp dd grep sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
[ "$(stat -c %s "$public_boot")" = "$partition_size" ] || fail public-boot-size
[ "$(stat -c %s "$stock_recovery")" = "$partition_size" ] || fail stock-recovery-size
[ "$(sha256sum "$stock_recovery" | awk '{print $1}')" = "$stock_recovery_sha256" ] ||
	fail stock-recovery-hash

public_info=$(avbtool info_image --image "$public_boot") || fail public-boot-avb
printf '%s\n' "$public_info" | grep -q '^Algorithm:[[:space:]]*NONE$' ||
	fail public-boot-avb-algorithm
printf '%s\n' "$public_info" | grep -q '^      Partition Name:[[:space:]]*boot$' ||
	fail public-boot-avb-partition
payload_size=$(printf '%s\n' "$public_info" |
	awk '/^Original image size:/ {print $4; exit}')
case $payload_size in ''|*[!0-9]*) fail public-boot-payload-size ;; esac
[ "$payload_size" -lt "$stock_vbmeta_offset" ] || fail public-payload-reaches-stock-vbmeta
[ $((payload_size % 4096)) -eq 0 ] || fail public-payload-not-page-aligned

stock_info=$(avbtool info_image --image "$stock_recovery") || fail stock-recovery-avb
[ "$(printf '%s\n' "$stock_info" | awk '/^VBMeta offset:/ {print $3; exit}')" = \
	"$stock_vbmeta_offset" ] || fail stock-vbmeta-offset
printf '%s\n' "$stock_info" | grep -q '^      Partition Name:[[:space:]]*recovery$' ||
	fail stock-avb-partition

tmp=$output.tmp
trap 'rm -f "$tmp"' EXIT HUP INT TERM
cp "$stock_recovery" "$tmp"
dd if="$public_boot" of="$tmp" bs=4096 count=$((payload_size / 4096)) \
	conv=notrunc status=none
cmp -n "$payload_size" "$public_boot" "$tmp" || fail hybrid-prefix
cmp -i "$payload_size" "$stock_recovery" "$tmp" || fail hybrid-tail
mv "$tmp" "$output"
trap - EXIT HUP INT TERM
(
	cd "$(dirname -- "$output")"
	sha256sum "$(basename -- "$output")" >"$(basename -- "$output").sha256"
)
cat >"$output.metadata" <<EOF
format=m1892-public-recovery-hybrid-v1
public_boot_sha256=$(sha256sum "$public_boot" | awk '{print $1}')
public_payload_size=$payload_size
stock_recovery_sha256=$stock_recovery_sha256
stock_vbmeta_offset=$stock_vbmeta_offset
output_sha256=$(sha256sum "$output" | awk '{print $1}')
EOF
echo "recovery_sha256=$(sha256sum "$output" | awk '{print $1}')"
echo M1892_PUBLIC_RECOVERY_PASS
