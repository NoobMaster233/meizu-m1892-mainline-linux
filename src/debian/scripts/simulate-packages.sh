#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
config=${1:-$tree_dir/config/rootfs.env.example}
[ -r "$config" ] || { echo "M1892_DEBIAN_SIMULATION_FAIL: unreadable-config:$config" >&2; exit 1; }
config=$(readlink -f "$config")
M1892_DEBIAN_CONFIG_DIR=$(dirname "$config")
export M1892_DEBIAN_CONFIG_DIR

# The tracked example is also the reproducible public package contract. A private
# local.env may override it later, but must never contain owner credentials here.
# shellcheck disable=SC1090
. "$config"

mmdebstrap_bin=${M1892_MMDEBSTRAP:-$(command -v mmdebstrap 2>/dev/null || true)}
[ -n "$mmdebstrap_bin" ] && [ -x "$mmdebstrap_bin" ] || {
	echo 'M1892_DEBIAN_SIMULATION_FAIL: missing-mmdebstrap' >&2
	exit 1
}

if [ -n "${M1892_DEBIAN_KEYRING:-}" ]; then
	keyring=$M1892_DEBIAN_KEYRING
else
	mmdebstrap_real=$(readlink -f "$mmdebstrap_bin")
	prefix_keyring=$(dirname -- "$(dirname -- "$mmdebstrap_real")")/share/keyrings/debian-archive-keyring.gpg
	if [ -r "$prefix_keyring" ]; then
		keyring=$prefix_keyring
	else
		keyring=/usr/share/keyrings/debian-archive-keyring.gpg
	fi
fi
[ -r "$keyring" ] || {
	echo "M1892_DEBIAN_SIMULATION_FAIL: unreadable-keyring:$keyring" >&2
	exit 1
}

version=$($mmdebstrap_bin --version 2>&1 | awk 'NR==1 {print $2}')
[ "$version" = "$M1892_MMDEBSTRAP_VERSION" ] || {
	echo "M1892_DEBIAN_SIMULATION_FAIL: mmdebstrap-version:$version" >&2
	exit 1
}

packages=$M1892_DEBIAN_BASE_PACKAGES,$M1892_PLASMA_PACKAGES
if [ -n "${M1892_PHONE_PACKAGES:-}" ]; then
	packages=$packages,$M1892_PHONE_PACKAGES
fi
if [ -n "${M1892_DAILY_PACKAGES:-}" ]; then
	packages=$packages,$M1892_DAILY_PACKAGES
fi
components=$(printf '%s' "$M1892_DEBIAN_COMPONENTS" | tr ',' ' ')
sources=$(printf '%s\n' \
	"deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE $components" \
	"deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-updates $components" \
	"deb [check-valid-until=no] $M1892_DEBIAN_SECURITY_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-security $components")
evidence_dir=${M1892_DEBIAN_EVIDENCE_DIR:-$tree_dir/out/evidence}
mkdir -p "$evidence_dir"
log_file=$evidence_dir/package-simulation.log
summary_file=$evidence_dir/package-simulation.env
started_epoch=$(date +%s)

{
	printf 'suite=%s\n' "$M1892_DEBIAN_SUITE"
	printf 'architecture=%s\n' "$M1892_DEBIAN_ARCH"
	printf 'mirror=%s\n' "$M1892_DEBIAN_MIRROR"
	printf 'security_mirror=%s\n' "$M1892_DEBIAN_SECURITY_MIRROR"
	printf 'snapshot=%s\n' "$M1892_DEBIAN_SNAPSHOT"
	printf 'components=%s\n' "$M1892_DEBIAN_COMPONENTS"
	printf 'mmdebstrap_version=%s\n' "$version"
	printf 'mode=unshare\n'
	printf 'started_epoch=%s\n' "$started_epoch"
	printf 'packages=%s\n' "$packages"
} > "$summary_file"

if "$mmdebstrap_bin" \
	--simulate \
	--mode=unshare \
	--format=null \
	--variant=minbase \
	--architectures="$M1892_DEBIAN_ARCH" \
	--components="$M1892_DEBIAN_COMPONENTS" \
	--keyring="$keyring" \
	--include="$packages" \
	"$M1892_DEBIAN_SUITE" /dev/null "$sources" \
	>"$log_file" 2>&1; then
	finished_epoch=$(date +%s)
	{
		printf 'finished_epoch=%s\n' "$finished_epoch"
		printf 'elapsed_seconds=%s\n' "$((finished_epoch - started_epoch))"
		printf 'result=pass\n'
	} >> "$summary_file"
	echo M1892_DEBIAN_PACKAGE_SIMULATION_PASS
else
	finished_epoch=$(date +%s)
	{
		printf 'finished_epoch=%s\n' "$finished_epoch"
		printf 'elapsed_seconds=%s\n' "$((finished_epoch - started_epoch))"
		printf 'result=fail\n'
	} >> "$summary_file"
	echo "M1892_DEBIAN_SIMULATION_FAIL: see:$log_file" >&2
	exit 1
fi
