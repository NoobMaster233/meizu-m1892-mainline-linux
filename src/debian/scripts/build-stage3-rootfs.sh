#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
output_dir=${1:-}
config=${2:-$tree_dir/config/stage3.env}
[ -n "$output_dir" ] || {
	echo "usage: $0 ABSOLUTE_OUTPUT_DIR [CONFIG]" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_STAGE3_BUILD_FAIL: output-not-absolute' >&2; exit 2 ;; esac
[ -r "$config" ] || { echo 'M1892_DEBIAN_STAGE3_BUILD_FAIL: unreadable-config' >&2; exit 2; }
config=$(readlink -f "$config")
M1892_DEBIAN_CONFIG_DIR=$(dirname "$config")
export M1892_DEBIAN_CONFIG_DIR

# shellcheck disable=SC1090
. "$config"
fail() { echo "M1892_DEBIAN_STAGE3_BUILD_FAIL: $*" >&2; exit 1; }
sensor_debs=${M1892_STAGE3_SENSOR_DEBS_DIR:-}
media_debs=${M1892_STAGE3_MEDIA_DEBS_DIR:-}
plasma_settings_debs=${M1892_STAGE6_PLASMA_SETTINGS_DEBS_DIR:-}
[ -d "$sensor_debs" ] || fail sensor-backport-directory-absent
[ -d "$media_debs" ] || fail media-tools-directory-absent
"$script_dir/install-stage3-sensor-backport.sh" --check "$sensor_debs"
"$script_dir/install-stage3-media-tools.sh" --check "$media_debs"
if [ -n "${M1892_PLASMA_SETTINGS_VERSION:-}" ]; then
	[ -d "$plasma_settings_debs" ] || fail plasma-settings-directory-absent
	"$script_dir/install-stage6-plasma-settings.sh" --check "$plasma_settings_debs"
fi
case "$M1892_DEBIAN_SNAPSHOT" in ????????T??????Z) ;; *) fail invalid-snapshot ;; esac
case "$M1892_SOURCE_DATE_EPOCH" in ''|*[!0-9]*) fail invalid-source-date-epoch ;; esac
[ "$M1892_DEBIAN_ARCH" = arm64 ] || fail unsupported-architecture
[ "$M1892_DEBIAN_SUITE" = trixie ] || fail unsupported-suite
case "$M1892_STAGE3_ARTIFACT" in *.tar) ;; *) fail invalid-artifact-name ;; esac

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
packages=$M1892_DEBIAN_BASE_PACKAGES,$M1892_PLASMA_PACKAGES,$M1892_PHONE_PACKAGES
if [ -n "${M1892_DAILY_PACKAGES:-}" ]; then
	packages=$packages,$M1892_DAILY_PACKAGES
fi
artifact=$output_dir/$M1892_STAGE3_ARTIFACT
log=$output_dir/mmdebstrap.log
summary=$output_dir/build.env
started_epoch=$(date +%s)

{
	printf 'stage=%s\n' "$M1892_STAGE3_LABEL"
	printf 'suite=%s\narchitecture=%s\nsnapshot=%s\n' \
		"$M1892_DEBIAN_SUITE" "$M1892_DEBIAN_ARCH" "$M1892_DEBIAN_SNAPSHOT"
	printf 'source_date_epoch=%s\nvariant=minbase\nmode=unshare\n' "$M1892_SOURCE_DATE_EPOCH"
	printf 'sensor_backport_packages=%s\n' "$M1892_SENSOR_BACKPORT_PACKAGES"
	printf 'media_tool_packages=%s\n' "$M1892_MEDIA_TOOL_PACKAGES"
	printf 'daily_packages=%s\n' "${M1892_DAILY_PACKAGES:-none}"
	printf 'plasma_settings_version=%s\n' "${M1892_PLASMA_SETTINGS_VERSION:-distribution}"
	printf 'install_recommends=no\npackages=%s\n' "$packages"
	printf 'config_sha256=%s\nbuilder_sha256=%s\nfinalizer_sha256=%s\n' \
		"$(sha256sum "$config" | awk '{print $1}')" \
		"$(sha256sum "$0" | awk '{print $1}')" \
		"$(sha256sum "$script_dir/finalize-stage3-rootfs.sh" | awk '{print $1}')"
	printf 'keyring_sha256=%s\nstarted_epoch=%s\n' \
		"$(sha256sum "$keyring" | awk '{print $1}')" "$started_epoch"
} >"$summary"

export SOURCE_DATE_EPOCH=$M1892_SOURCE_DATE_EPOCH
set --
if [ -n "${M1892_PLASMA_SETTINGS_VERSION:-}" ]; then
	set -- "--customize-hook=$script_dir/install-stage6-plasma-settings.sh \"\$1\" \"$plasma_settings_debs\""
fi
"$mmdebstrap_bin" \
	--mode=unshare \
	--format=tar \
	--variant=minbase \
	--architectures="$M1892_DEBIAN_ARCH" \
	--keyring="$keyring" \
	--aptopt='Acquire::Languages "none"' \
	--aptopt='APT::Install-Recommends "false"' \
	--include="$packages" \
	--customize-hook="$script_dir/install-stage3-sensor-backport.sh \"\$1\" \"$sensor_debs\"" \
	--customize-hook="$script_dir/install-stage3-media-tools.sh \"\$1\" \"$media_debs\"" \
	"$@" \
	--customize-hook="$script_dir/finalize-stage3-rootfs.sh \"\$1\"" \
	--logfile="$log" \
	"$M1892_DEBIAN_SUITE" "$artifact" "$sources"

finished_epoch=$(date +%s)
sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
{
	printf 'finished_epoch=%s\nelapsed_seconds=%s\n' "$finished_epoch" "$((finished_epoch - started_epoch))"
	printf 'artifact_size=%s\nartifact_sha256=%s\nresult=pass\n' "$bytes" "$sha"
} >>"$summary"
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"

echo "artifact=$artifact"
echo "artifact_size=$bytes"
echo "artifact_sha256=$sha"
echo M1892_DEBIAN_STAGE3_ROOTFS_BUILD_PASS
