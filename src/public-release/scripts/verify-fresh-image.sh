#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
public_verifier=$script_dir/../src/rootfs/verify-m1892-r6-fresh-image.sh
[ -x "$public_verifier" ] || {
	echo "M1892_FRESH_IMAGE_FAIL: missing-public-verifier" >&2
	exit 1
}
exec "$public_verifier" "$@"
