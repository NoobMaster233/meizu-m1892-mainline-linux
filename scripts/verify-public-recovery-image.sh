#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

recovery=${1:-}
public_boot=${2:-}
stock_recovery=${3:-}
partition_size=67108864
stock_vbmeta_offset=26091520
stock_recovery_sha256=faffac470b6eb984167b48c303177efd9fb20be2b2d5f0402d06a3a49605a997
fail() { echo "M1892_PUBLIC_RECOVERY_VERIFY_FAIL: $*" >&2; exit 1; }
for file in "$recovery" "$public_boot" "$stock_recovery"; do
	[ -f "$file" ] || fail "missing-input:$file"
done
for command in avbtool awk cmp grep sha256sum stat; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
for file in "$recovery" "$public_boot" "$stock_recovery"; do
	[ "$(stat -c %s "$file")" = "$partition_size" ] || fail "size:$file"
done
[ "$(sha256sum "$stock_recovery" | awk '{print $1}')" = "$stock_recovery_sha256" ] ||
	fail stock-recovery-hash

public_info=$(avbtool info_image --image "$public_boot") || fail public-boot-avb
printf '%s\n' "$public_info" | grep -q '^Algorithm:[[:space:]]*NONE$' ||
	fail public-boot-avb-algorithm
payload_size=$(printf '%s\n' "$public_info" |
	awk '/^Original image size:/ {print $4; exit}')
case $payload_size in ''|*[!0-9]*) fail public-payload-size ;; esac
[ "$payload_size" -lt "$stock_vbmeta_offset" ] || fail public-payload-reaches-stock-vbmeta
[ $((payload_size % 4096)) -eq 0 ] || fail public-payload-not-page-aligned

hybrid_info=$(avbtool info_image --image "$recovery") || fail hybrid-stock-avb-tail
[ "$(printf '%s\n' "$hybrid_info" | awk '/^VBMeta offset:/ {print $3; exit}')" = \
	"$stock_vbmeta_offset" ] || fail hybrid-stock-vbmeta-offset
printf '%s\n' "$hybrid_info" | grep -q '^      Partition Name:[[:space:]]*recovery$' ||
	fail hybrid-stock-avb-partition
cmp -n "$payload_size" "$public_boot" "$recovery" || fail hybrid-prefix
cmp -i "$payload_size" "$stock_recovery" "$recovery" || fail hybrid-tail

printf 'recovery_sha256=%s\n' "$(sha256sum "$recovery" | awk '{print $1}')"
printf 'public_payload_size=%s\n' "$payload_size"
echo M1892_PUBLIC_RECOVERY_VERIFY_PASS
