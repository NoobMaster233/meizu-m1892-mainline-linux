#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

# Rebuild the exact Phoc 0.56.0 binary used by the M1892 R523 fix.  Run this
# on aarch64 Alpine edge (the phone itself or an equivalent disposable root),
# not on the daily phone root unless temporary build dependencies are isolated.

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
mainline_dir=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
source_url=https://sources.phosh.mobi/releases/phoc/phoc-0.56.0.tar.xz
source_sha512=f2a22e04fc00dfde56c83750ff531b6debcf2af81b913f8d85f8b23e1dc1fd71ec3786d2f2e963ed3e3b1b4b8703ed9844452d20619fac729de5482be77b7a7b
patch_file=$mainline_dir/patches/0001-phoc-input-method-fix-keyboard-grab-destroy-null.patch
work_dir=${1:-/tmp/m1892-phoc-r523-build}
artifact=${2:-$script_dir/artifacts/r523/phoc-0.56.0-r0-m1892-r523}
tarball=$work_dir/phoc-0.56.0.tar.xz
source_dir=$work_dir/phoc-0.56.0
build_dir=$work_dir/output

fail() { echo "M1892_R523_PHOC_BUILD_FAIL: $*" >&2; exit 1; }

for command in curl meson ninja patch sha512sum strip tar; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

test -f "$patch_file" || fail "missing-patch:$patch_file"
mkdir -p "$work_dir" "$(dirname -- "$artifact")"
if ! test -f "$tarball"; then
	curl -L --fail --output "$tarball" "$source_url"
fi
printf '%s  %s\n' "$source_sha512" "$tarball" | sha512sum -c -
test ! -e "$source_dir" || fail "source-dir-exists:$source_dir"
tar -C "$work_dir" -xf "$tarball"
patch -d "$source_dir" -p1 <"$patch_file"

meson setup "$build_dir" "$source_dir" \
	--buildtype=debugoptimized \
	-Db_lto=true \
	-Dembed-wlroots=enabled \
	-Dman=false \
	-Dtests=false \
	-Ddefault_library=static \
	--prefix=/usr
meson compile -C "$build_dir"
install -m 0755 "$build_dir/src/phoc" "$artifact"
strip --strip-unneeded "$artifact"

"$artifact" --version
sha256sum "$artifact"
echo M1892_R523_PHOC_BUILD_PASS
