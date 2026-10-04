#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/commissioning-geometry.sh"
pass=0
expect()
{
	expected=$1; shift
	actual=fail
	if m1892_validate_userdata_geometry "$@"; then actual=pass; fi
	[ "$actual" = "$expected" ] || { echo "geometry test failed: $expected $*" >&2; exit 1; }
	pass=$((pass + 1))
}
expect pass 5368709120 12204608 235783576 4096 120721190912
# 64 GiB nominal storage, equivalent userdata after the same protected prefix.
capacity64=$((64 * 1024 * 1024 * 1024 - 12204608 * 512))
expect pass 5368709120 12204608 $((capacity64 / 512)) 4096 "$capacity64"
expect pass 5368709120 12204608 $((capacity64 / 512)) 512 "$capacity64"
expect fail 5368709120 0 235783576 4096 120721190912
expect fail 5368709121 12204608 235783576 4096 120721190912
expect fail 5368709120 12204608 10485760 4096 5368709120
expect fail 5368709120 12204608 235783575 4096 120721190912
expect fail 5368709120 12204608 235783576 8192 120721190912
expect fail 5368709120 12204609 235783576 4096 120721190912
expect fail nope 12204608 235783576 4096 120721190912
expect fail 99999999999999999999 12204608 235783576 4096 120721190912
echo "M1892_COMMISSION_GEOMETRY_TEST_PASS cases=$pass"
