#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

mode=${1:-host}
case "$mode" in
	host|kernel-host|arm-builder) ;;
	*) echo "usage: $0 host|kernel-host|arm-builder" >&2; exit 2 ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_dir=$(git -C "$tree_dir" rev-parse --show-toplevel)
baseline=m1892-postmarketos-phosh-pre-debian-20260907
minimum_kib=$((30 * 1024 * 1024))
build_root=${M1892_DEBIAN_BUILD_ROOT:-$repo_dir/.build-preflight}
mmdebstrap_bin=${M1892_MMDEBSTRAP:-}

fail() { echo "M1892_DEBIAN_PREFLIGHT_FAIL: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing-command:$1"; }

# Private development ancestry is not exported. A public checkout instead
# validates the complete allowlisted source manifest before preflight proceeds.
if [ "$tree_dir" = "$repo_dir/src/debian" ] && [ -f "$repo_dir/tools/verify-source.py" ]; then
	python3 "$repo_dir/tools/verify-source.py" "$repo_dir" || fail public-source-contract
	baseline_identity=public-source-manifest
else
	git -C "$repo_dir" merge-base --is-ancestor "$baseline" HEAD || fail baseline-not-ancestor
	baseline_identity=$(git -C "$repo_dir" rev-list -n 1 "$baseline")
fi
case "$build_root" in /*) ;; *) fail build-root-not-absolute ;; esac
fs_type=$(stat -f -c %T "$(dirname -- "$build_root")")
case "$fs_type" in ext2/ext3|ext4) ;; *) fail "build-root-not-native-ext:$fs_type" ;; esac
available_kib=$(df -Pk "$(dirname -- "$build_root")" | awk 'NR==2 {print $4}')
[ "$available_kib" -ge "$minimum_kib" ] || fail "insufficient-space-kib:$available_kib"

for command in awk df git sha256sum stat tar xz zstd; do need "$command"; done

case "$mode" in
	host)
		if [ -z "$mmdebstrap_bin" ]; then
			mmdebstrap_bin=$(command -v mmdebstrap 2>/dev/null || true)
		fi
		[ -n "$mmdebstrap_bin" ] && [ -x "$mmdebstrap_bin" ] ||
			fail missing-mmdebstrap
		need aarch64-linux-gnu-gcc
		need arch-test
		need newgidmap
		need newuidmap
		need qemu-aarch64-static
		need unshare
		[ "$(uname -m)" = x86_64 ] || fail unexpected-host-architecture
		unshare --user --map-root-user true 2>/dev/null || fail unprivileged-userns
		[ -u "$(command -v newuidmap)" ] || fail newuidmap-not-setuid
		[ -u "$(command -v newgidmap)" ] || fail newgidmap-not-setuid
		arch-test arm64 >/dev/null 2>&1 || fail arm64-binfmt
		;;
	kernel-host)
		for command in aarch64-linux-gnu-gcc dtc fdtget fdtput fdtoverlay \
			make modinfo pahole; do
			need "$command"
		done
		[ "$(uname -m)" = x86_64 ] || fail unexpected-host-architecture
		aarch64-linux-gnu-gcc --version | head -n 1 |
			grep -q '11\.4\.0' || fail compiler-version
		;;
	arm-builder)
		if [ -z "$mmdebstrap_bin" ]; then
			mmdebstrap_bin=$(command -v mmdebstrap 2>/dev/null || true)
		fi
		[ -n "$mmdebstrap_bin" ] && [ -x "$mmdebstrap_bin" ] ||
			fail missing-mmdebstrap
		[ "$(uname -m)" = aarch64 ] || fail not-native-arm64
		need gcc
		need make
		;;
esac

printf 'mode=%s\n' "$mode"
printf 'baseline_commit=%s\n' "$baseline_identity"
printf 'head=%s\n' "$(git -C "$repo_dir" rev-parse HEAD)"
printf 'build_root=%s\n' "$build_root"
printf 'filesystem=%s\n' "$fs_type"
printf 'available_kib=%s\n' "$available_kib"
if [ "$mode" = kernel-host ]; then
	echo mmdebstrap=not-required
else
	printf 'mmdebstrap=%s\n' "$($mmdebstrap_bin --version | head -1)"
fi
echo M1892_DEBIAN_PREFLIGHT_PASS
