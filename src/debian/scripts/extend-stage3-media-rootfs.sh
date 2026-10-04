#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
debs=${2:-}
output_dir=${3:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
[ -f "$base" ] && [ -d "$debs" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_STAGE3_TAR MEDIA_DEBS NEW_OUTPUT_DIRECTORY" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_MEDIA_EXTEND_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ -f "$base.sha256" ] || { echo 'M1892_MEDIA_EXTEND_FAIL: base-sidecar' >&2; exit 1; }
(cd "$(dirname "$base")" && sha256sum -c "$(basename "$base").sha256") >/dev/null ||
	{ echo 'M1892_MEDIA_EXTEND_FAIL: base-hash' >&2; exit 1; }
"$script_dir/install-stage3-media-tools.sh" --check "$debs"
[ ! -e "$output_dir" ] || { echo 'M1892_MEDIA_EXTEND_FAIL: output-exists' >&2; exit 1; }

for command in find install mktemp sha256sum stat tar touch unshare; do
	command -v "$command" >/dev/null || { echo "M1892_MEDIA_EXTEND_FAIL: command:$command" >&2; exit 1; }
done

# shellcheck disable=SC1090
. "$tree_dir/config/stage3.env"
work=$(mktemp -d /tmp/m1892-media-extend.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output_dir"
# The archive is only a staging input.  Keep extraction rootless and write
# canonical uid/gid 0 into the new archive at the final boundary.  Mixing
# fakeroot's pathname database with a nested user namespace makes dpkg's
# symlink-to-regular-file replacements stale and caused GNU tar readlink
# failures for dpkg metadata files.
tar --no-same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev" "$root/run/m1892-media-tools"
for file in "$debs"/*.deb; do
	install -m 0644 "$file" "$root/run/m1892-media-tools/$(basename "$file")"
done

env -u LD_PRELOAD -u FAKEROOTKEY \
	unshare --map-root-user --mount --pid --fork --mount-proc=/proc --root="$root" \
	/usr/bin/dpkg -i \
	/run/m1892-media-tools/libv4l2rds0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/libv4lconvert0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/libv4l-0t64_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/v4l-utils_1.30.1-1_arm64.deb \
	/run/m1892-media-tools/gstreamer1.0-tools_1.26.2-2_arm64.deb
find "$root/run/m1892-media-tools" -depth -delete
# Match the canonical cleanup performed by finalize-stage3-rootfs.sh.  These
# two build-host state files were the only byte differences in an A/B rebuild.
rm -f "$root/var/cache/ldconfig/aux-cache"
: >"$root/var/log/dpkg.log"
find "$root" -xdev -exec touch -h -d "@$M1892_SOURCE_DATE_EPOCH" {} +

artifact=$output_dir/$M1892_STAGE3_ARTIFACT
tar --sort=name --numeric-owner --owner=0 --group=0 --format=gnu -cf "$artifact" -C "$root" .
sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
{
	printf 'stage=%s-media-extension\n' "$M1892_STAGE3_LABEL"
	printf 'base_sha256=%s\n' "$(sha256sum "$base" | awk '{print $1}')"
	printf 'media_tool_packages=%s\n' "$M1892_MEDIA_TOOL_PACKAGES"
	printf 'artifact_size=%s\nartifact_sha256=%s\nresult=pass\n' "$bytes" "$sha"
} >"$output_dir/build.env"
echo "artifact=$artifact"
echo "artifact_size=$bytes"
echo "artifact_sha256=$sha"
echo M1892_MEDIA_EXTEND_PASS
