#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

build=${1:-}
archive=${2:-}
fail() { echo "M1892_PUBLIC_KERNEL_PACKAGE_FAIL: $*" >&2; exit 1; }
[ -d "$build" ] || fail missing-build-directory
[ -n "$archive" ] || { echo "usage: $0 KERNEL_BUILD_DIRECTORY NEW_ARCHIVE" >&2; exit 2; }
[ ! -e "$archive" ] || fail archive-exists
[ ! -e "$archive.sha256" ] || fail sidecar-exists
for command in basename dirname gzip mkdir mv realpath rm sha256sum tar; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

build=$(CDPATH='' cd -- "$build" && pwd)
archive=$(realpath -m "$archive")
mkdir -p "$(dirname -- "$archive")"
files='M1892-KERNEL-BUILD-MANIFEST.txt
.config
System.map
arch/arm64/boot/Image.gz
arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb
drivers/gpu/drm/panel/panel-samsung-sofef00m.ko
drivers/firmware/cirrus/cs_dsp.ko
sound/soc/codecs/snd-soc-wm-adsp.ko
sound/soc/codecs/snd-soc-cs35l41-lib.ko
sound/soc/codecs/snd-soc-cs35l41.ko
sound/soc/codecs/snd-soc-cs35l41-spi.ko
sound/soc/qcom/snd-soc-sdm845.ko'
for file in $files; do
	[ -f "$build/$file" ] || fail "missing-input:$file"
done

tmp=$archive.tmp.$$
cleanup() { rm -f "$tmp"; }
trap cleanup EXIT HUP INT TERM
# Fixed ordering, ownership and timestamps make a locally built artifact and
# its GitHub Actions counterpart byte-identical when their kernel inputs match.
(cd "$build" && tar --sort=name --mtime=@1778300477 --owner=0 --group=0 \
	--numeric-owner -cf - $files) | gzip -n >"$tmp"
mv "$tmp" "$archive"
(cd "$(dirname -- "$archive")" && sha256sum "$(basename -- "$archive")") \
	>"$archive.sha256"
echo "archive=$archive"
cat "$archive.sha256"
echo M1892_PUBLIC_KERNEL_PACKAGE_PASS
