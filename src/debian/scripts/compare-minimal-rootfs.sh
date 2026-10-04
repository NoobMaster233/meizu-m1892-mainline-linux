#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

left=${1:-}
right=${2:-}
[ -d "$left" ] && [ -d "$right" ] || {
	echo "usage: $0 BUILD_A_DIR BUILD_B_DIR" >&2
	exit 2
}
fail() { echo "M1892_DEBIAN_REPRODUCIBILITY_FAIL: $*" >&2; exit 1; }

name=m1892-debian13-minbase-arm64.tar
for dir in "$left" "$right"; do
	[ -r "$dir/$name" ] || fail missing-artifact
	[ -r "$dir/evidence/packages.tsv" ] || fail missing-package-manifest
	[ -r "$dir/evidence/licenses.tsv" ] || fail missing-license-manifest
	[ -r "$dir/evidence/files.sha256" ] || fail missing-file-manifest
	[ -r "$dir/evidence/tar-metadata.txt" ] || fail missing-tar-metadata
done

cmp -s "$left/evidence/packages.tsv" "$right/evidence/packages.tsv" || fail package-manifest-differs
cmp -s "$left/evidence/licenses.tsv" "$right/evidence/licenses.tsv" || fail license-manifest-differs
cmp -s "$left/evidence/files.sha256" "$right/evidence/files.sha256" || fail file-manifest-differs
cmp -s "$left/evidence/tar-metadata.txt" "$right/evidence/tar-metadata.txt" || fail tar-metadata-differs
cmp -s "$left/$name" "$right/$name" || fail tar-bytes-differ

sha=$(sha256sum "$left/$name" | awk '{print $1}')
echo "artifact_sha256=$sha"
echo M1892_DEBIAN_STAGE1_REPRODUCIBILITY_PASS
