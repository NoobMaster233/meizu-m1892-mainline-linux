#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_dir=${1:-}
[ -d "$source_dir" ] || {
	echo "M1892_PUBLIC_EDK2_SUBMODULES_FAIL: missing-source" >&2
	exit 1
}

git -C "$source_dir" submodule update --init \
	Common/edk2 \
	Common/edk2-platforms \
	GPLDrivers/Library/SimpleInit \
	Platform/EFI_Binaries \
	tools/Installer
git -C "$source_dir/Common/edk2" submodule update --init \
	BaseTools/Source/C/BrotliCompress/brotli \
	CryptoPkg/Library/OpensslLib/openssl \
	MdeModulePkg/Library/BrotliCustomDecompressLib/brotli
git -C "$source_dir/GPLDrivers/Library/SimpleInit" submodule update --init \
	libs/freetype

echo M1892_PUBLIC_EDK2_SUBMODULES_PASS
