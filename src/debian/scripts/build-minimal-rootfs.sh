#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
config=${2:-$tree_dir/config/rootfs.env.example}
output_dir=${1:-}
[ -n "$output_dir" ] || {
	echo "usage: $0 ABSOLUTE_OUTPUT_DIR [CONFIG]" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_BUILD_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ -r "$config" ] || { echo 'M1892_DEBIAN_BUILD_FAIL: unreadable-config' >&2; exit 2; }

# shellcheck disable=SC1090
. "$config"

fail() { echo "M1892_DEBIAN_BUILD_FAIL: $*" >&2; exit 1; }
case "$M1892_DEBIAN_SNAPSHOT" in ????????T??????Z) ;; *) fail invalid-snapshot ;; esac
case "$M1892_SOURCE_DATE_EPOCH" in ''|*[!0-9]*) fail invalid-source-date-epoch ;; esac
[ "$M1892_DEBIAN_ARCH" = arm64 ] || fail unsupported-architecture
[ "$M1892_DEBIAN_SUITE" = trixie ] || fail unsupported-suite

if [ -e "$output_dir" ] && [ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
	fail output-not-empty
fi
mkdir -p "$output_dir"

mmdebstrap_bin=${M1892_MMDEBSTRAP:-$(command -v mmdebstrap 2>/dev/null || true)}
[ -n "$mmdebstrap_bin" ] && [ -x "$mmdebstrap_bin" ] || fail missing-mmdebstrap
version=$($mmdebstrap_bin --version 2>&1 | awk 'NR==1 {print $2}')
[ "$version" = "$M1892_MMDEBSTRAP_VERSION" ] || fail "mmdebstrap-version:$version"

if [ -n "${M1892_DEBIAN_KEYRING:-}" ]; then
	keyring=$M1892_DEBIAN_KEYRING
else
	mmdebstrap_real=$(readlink -f "$mmdebstrap_bin")
	prefix_keyring=$(dirname -- "$(dirname -- "$mmdebstrap_real")")/share/keyrings/debian-archive-keyring.gpg
	if [ -r "$prefix_keyring" ]; then keyring=$prefix_keyring; else keyring=/usr/share/keyrings/debian-archive-keyring.gpg; fi
fi
[ -r "$keyring" ] || fail unreadable-keyring

components=$(printf '%s' "$M1892_DEBIAN_COMPONENTS" | tr ',' ' ')
sources=$(printf '%s\n' \
	"deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE $components" \
	"deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-updates $components" \
	"deb [check-valid-until=no] $M1892_DEBIAN_SECURITY_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-security $components")

artifact=$output_dir/m1892-debian13-minbase-arm64.tar
log=$output_dir/mmdebstrap.log
summary=$output_dir/build.env
started_epoch=$(date +%s)
config_sha=$(sha256sum "$config" | awk '{print $1}')
builder_sha=$(sha256sum "$0" | awk '{print $1}')
finalizer_sha=$(sha256sum "$script_dir/finalize-minimal-rootfs.sh" | awk '{print $1}')

{
	printf 'suite=%s\n' "$M1892_DEBIAN_SUITE"
	printf 'architecture=%s\n' "$M1892_DEBIAN_ARCH"
	printf 'snapshot=%s\n' "$M1892_DEBIAN_SNAPSHOT"
	printf 'source_date_epoch=%s\n' "$M1892_SOURCE_DATE_EPOCH"
	printf 'variant=minbase\nmode=unshare\n'
	printf 'base_packages=%s\n' "$M1892_DEBIAN_BASE_PACKAGES"
	printf 'config_sha256=%s\n' "$config_sha"
	printf 'builder_sha256=%s\n' "$builder_sha"
	printf 'finalizer_sha256=%s\n' "$finalizer_sha"
	printf 'keyring_sha256=%s\n' "$(sha256sum "$keyring" | awk '{print $1}')"
	printf 'started_epoch=%s\n' "$started_epoch"
} >"$summary"

export SOURCE_DATE_EPOCH=$M1892_SOURCE_DATE_EPOCH
"$mmdebstrap_bin" \
	--mode=unshare \
	--format=tar \
	--variant=minbase \
	--architectures="$M1892_DEBIAN_ARCH" \
	--keyring="$keyring" \
	--aptopt='Acquire::Languages "none"' \
	--include="$M1892_DEBIAN_BASE_PACKAGES" \
	--customize-hook="$script_dir/finalize-minimal-rootfs.sh \"\$1\"" \
	--logfile="$log" \
	"$M1892_DEBIAN_SUITE" "$artifact" "$sources"

finished_epoch=$(date +%s)
artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
artifact_size=$(stat -c %s "$artifact")
{
	printf 'finished_epoch=%s\n' "$finished_epoch"
	printf 'elapsed_seconds=%s\n' "$((finished_epoch - started_epoch))"
	printf 'artifact_size=%s\n' "$artifact_size"
	printf 'artifact_sha256=%s\n' "$artifact_sha"
	printf 'result=pass\n'
} >>"$summary"
printf '%s  %s\n' "$artifact_sha" "$(basename "$artifact")" >"$artifact.sha256"

echo "artifact=$artifact"
echo "artifact_size=$artifact_size"
echo "artifact_sha256=$artifact_sha"
echo M1892_DEBIAN_MINIMAL_BUILD_PASS
