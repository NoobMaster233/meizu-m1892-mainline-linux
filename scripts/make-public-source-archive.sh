#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_tree=${1:-}
archive=${2:-}
release_name=m1892-mainline-linux-2026.09-developer-preview.17
fail() { echo "M1892_PUBLIC_ARCHIVE_FAIL: $*" >&2; exit 1; }
[ -d "$source_tree" ] || fail missing-source-tree
[ -n "$archive" ] || fail missing-output-archive
[ ! -e "$archive" ] || fail output-exists
[ ! -e "$archive.sha256" ] || fail output-sidecar-exists
for command in find gzip sha256sum sort tar; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

source_tree=$(CDPATH='' cd -- "$source_tree" && pwd)
archive_parent=$(dirname -- "$archive")
archive_name=$(basename -- "$archive")
mkdir -p "$archive_parent"
archive_parent=$(CDPATH='' cd -- "$archive_parent" && pwd)
archive=$archive_parent/$archive_name
case $archive in
"$source_tree"/*) fail output-inside-source-tree ;;
esac

"$source_tree/scripts/verify-public-tree.sh" "$source_tree"
(cd "$source_tree" && sha256sum -c SOURCE-MANIFEST.sha256 >/dev/null) ||
	fail source-manifest

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-public-archive.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
list=$work/files.list
uncompressed_archive=$work/source.tar
temporary_archive=$work/source.tar.gz
(cd "$source_tree" && find . -mindepth 1 \
	! -path './.git' ! -path './.git/*' -print0 | LC_ALL=C sort -z) >"$list"
(cd "$source_tree" && tar --no-recursion --null --files-from="$list" \
	--sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
	--mode='u+rwX,go+rX,go-w' \
	--pax-option=delete=atime,delete=ctime \
	--transform="s,^\./,$release_name/," --format=posix \
	-cf "$uncompressed_archive")
gzip -n -9 <"$uncompressed_archive" >"$temporary_archive"
mv "$temporary_archive" "$archive"
(cd "$archive_parent" && sha256sum "$archive_name") >"$archive.sha256"

cat "$archive.sha256"
echo M1892_PUBLIC_ARCHIVE_PASS
