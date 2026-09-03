#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_dir=${1:-}
output_dir=${2:-}
[ -d "$source_dir" ] || { echo "M1892_PUBLIC_EDK2_FAIL: missing-source" >&2; exit 1; }
[ -n "$output_dir" ] || { echo "usage: $0 CLEAN_EDK2_SOURCE NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
[ ! -e "$output_dir" ] || { echo "M1892_PUBLIC_EDK2_FAIL: output-exists" >&2; exit 1; }

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tree_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
source_dir=$(realpath "$source_dir")
output_dir=$(realpath -m "$output_dir")
edk_source=$tree_root/src/edk2
if [ ! -d "$edk_source" ]; then
	edk_source=$script_dir/../../edk2-m1892-overlay
fi
edk_patch=$edk_source/patches/edk2-r540-direct-simpleinit-diagnostic.patch
simple_hold_patch=$edk_source/patches/simpleinit-direct-failure-hold.patch
simple_fdt_patch=$edk_source/patches/simpleinit-fdt-initrd-address.patch
static_config=$edk_source/simpleinit.static.uefi-r541-public-inner-diag.cfg
simple_dir=$source_dir/GPLDrivers/Library/SimpleInit

fail() { echo "M1892_PUBLIC_EDK2_FAIL: $*" >&2; exit 1; }
for command in awk cc date git mkdir realpath sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
for file in "$source_dir/build.sh" "$edk_patch" "$simple_hold_patch" \
	"$simple_fdt_patch" "$static_config"; do
	[ -f "$file" ] || fail "missing-file:$file"
done

require_commit()
{
	repo=$1 expected=$2 label=$3
	actual=$(git -C "$repo" rev-parse HEAD)
	[ "$actual" = "$expected" ] || fail "commit:$label:$actual"
}
require_commit "$source_dir" e1952621f419f8db60ed28271264e1b5184c571d edk2-sdm845
require_commit "$source_dir/Common/edk2" e7aac7fc137e247edad22f7ee53b9a1fba227397 edk2
require_commit "$source_dir/Common/edk2-platforms" 982212662c71b6c734b7578526071d6b78da3bcc edk2-platforms
require_commit "$simple_dir" 29e062805776db5ab7a61d07ef040d43aed71161 SimpleInit
require_commit "$source_dir/Common/edk2/CryptoPkg/Library/OpensslLib/openssl" \
	129058165d195e43a0ad10111b0c2e29bdf65980 openssl
require_commit "$source_dir/Common/edk2/MdeModulePkg/Library/BrotliCustomDecompressLib/brotli" \
	f4153a09f87cbb9c826d8fc12c74642bb2d879ea brotli
require_commit "$source_dir/Common/edk2/BaseTools/Source/C/BrotliCompress/brotli" \
	f4153a09f87cbb9c826d8fc12c74642bb2d879ea basetools-brotli
require_commit "$simple_dir/libs/freetype" \
	6a2b3e4007e794bfc6c91030d0ed987f925164a8 freetype

# BaseTools links against the host libuuid and SimpleInit consumes freetype.
# Fail here with a useful message instead of after a long firmware build.
printf '%s\n' '#include <uuid/uuid.h>' | \
	"${CC:-cc}" -E -x c - >/dev/null 2>&1 || fail missing-host-header:uuid/uuid.h
[ -r "$simple_dir/libs/freetype/include/freetype/freetype.h" ] ||
	fail missing-freetype-submodule
[ -r "$source_dir/Common/edk2/BaseTools/Source/C/BrotliCompress/brotli/c/include/brotli/decode.h" ] ||
	fail missing-basetools-brotli-submodule

[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ] ||
	fail dirty-edk2-source
[ -z "$(git -C "$simple_dir" status --porcelain --untracked-files=no)" ] ||
	fail dirty-simpleinit-source

apply_patch_once()
{
	repo=$1 patch=$2 label=$3
	if git -C "$repo" apply --unidiff-zero --check "$patch"; then
		git -C "$repo" apply --unidiff-zero "$patch"
	else
		fail "patch:$label"
	fi
}
apply_patch_once "$simple_dir" "$simple_fdt_patch" simpleinit-fdt
apply_patch_once "$simple_dir" "$simple_hold_patch" simpleinit-hold
apply_patch_once "$source_dir" "$edk_patch" edk2-direct-loader

mkdir -p "$output_dir"
cp "$static_config" "$source_dir/tools/simpleinit.static.uefi.cfg"
(
	cd "$source_dir"
	# SOURCE_DATE_EPOCH fixes compiler date/time macros where the toolchain
	# supports them. Upstream still embeds absolute build paths, so the loader
	# hash is recorded in the generated manifest instead of being promised as
	# path-independent byte reproducibility.
	SOURCE_DATE_EPOCH=1785081600 TZ=UTC ENABLE_LINUX_UTILS=1 \
		./build.sh --device m1892 --outputdir "$output_dir"
)
loader=$output_dir/workspace/uefi-m1892-kernel
[ -s "$loader" ] || fail missing-loader-output
manifest=$output_dir/M1892-EDK2-BUILD-MANIFEST.txt
cat >"$manifest" <<EOF
format=m1892-public-edk2-loader-v1
edk2_sdm845_commit=e1952621f419f8db60ed28271264e1b5184c571d
edk2_commit=e7aac7fc137e247edad22f7ee53b9a1fba227397
edk2_platforms_commit=982212662c71b6c734b7578526071d6b78da3bcc
simpleinit_commit=29e062805776db5ab7a61d07ef040d43aed71161
freetype_commit=6a2b3e4007e794bfc6c91030d0ed987f925164a8
basetools_brotli_commit=f4153a09f87cbb9c826d8fc12c74642bb2d879ea
static_config_sha256=$(sha256sum "$static_config" | awk '{print $1}')
edk2_patch_sha256=$(sha256sum "$edk_patch" | awk '{print $1}')
simpleinit_fdt_patch_sha256=$(sha256sum "$simple_fdt_patch" | awk '{print $1}')
simpleinit_hold_patch_sha256=$(sha256sum "$simple_hold_patch" | awk '{print $1}')
uefi_loader_sha256=$(sha256sum "$loader" | awk '{print $1}')
source_date_epoch=1785081600
EOF
echo "loader=$loader"
echo "manifest=$manifest"
echo M1892_PUBLIC_EDK2_PASS
