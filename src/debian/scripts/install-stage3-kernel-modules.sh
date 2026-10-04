#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_tree=${1:-}
kernel_build=${2:-}
output=${3:-}
fail() { echo "M1892_STAGE3_MODULE_INSTALL_FAIL: $*" >&2; exit 1; }
[ -d "$source_tree" ] && [ -f "$kernel_build/M1892-KERNEL-BUILD-MANIFEST.txt" ] &&
	[ -n "$output" ] || {
	echo "usage: $0 MATERIALIZED_KERNEL_TREE KERNEL_BUILD NEW_OUTPUT_DIRECTORY" >&2
	exit 2
}
[ ! -e "$output" ] || fail output-exists
for command in find getconf make mkdir readlink sha256sum sort stat xargs; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

manifest=$kernel_build/M1892-KERNEL-BUILD-MANIFEST.txt
grep -Fxq 'upstream_commit=85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8' "$manifest" ||
	fail upstream-commit
grep -Fxq 'compiler=aarch64-linux-gnu-gcc-11.4.0' "$manifest" ||
	fail compiler
kernel_release=$(make -s -C "$source_tree" O="$kernel_build" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= kernelrelease | tail -n 1)
[ "$kernel_release" = 7.1.0-rc1-sdm845 ] || fail "kernel-release:$kernel_release"

mkdir -p "$output"
make -C "$source_tree" O="$kernel_build" ARCH=arm64 \
	CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= \
	INSTALL_MOD_PATH="$output" INSTALL_MOD_STRIP=1 modules_install >/dev/null
module_root=$output/lib/modules/$kernel_release
[ -d "$module_root" ] || fail module-root-absent
for path in kernel/fs/fuse/fuse.ko \
	kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko \
	kernel/drivers/remoteproc/qcom_q6v5_mss.ko \
	kernel/drivers/gpu/drm/panel/panel-samsung-sofef00m.ko; do
	[ -f "$module_root/$path" ] || fail "required-module-absent:$path"
done

(cd "$module_root" && find . -type f -print | LC_ALL=C sort |
	xargs -r sha256sum) >"$output/MODULES.sha256"
module_count=$(find "$module_root" -type f -name '*.ko' | wc -l)
[ "$module_count" -gt 100 ] || fail "module-count:$module_count"
module_manifest_sha256=$(sha256sum "$output/MODULES.sha256" | awk '{print $1}')

{
	printf 'format=m1892-debian-kernel-modules-v1\n'
	printf 'kernel_release=%s\n' "$kernel_release"
	grep -E '^(upstream_commit|compiler|kernel_sha256|dtb_sha256|materialization_allowlist_sha256|materialization_package_map_sha256)=' "$manifest"
	printf 'venus_core_sha256=%s\n' \
		"$(sha256sum "$module_root/kernel/drivers/media/platform/qcom/venus/venus-core.ko" | awk '{print $1}')"
	printf 'module_count=%s\n' "$module_count"
	printf 'module_manifest_sha256=%s\n' "$module_manifest_sha256"
} >"$output/MODULES-METADATA.txt"

(cd "$module_root" && sha256sum -c "$output/MODULES.sha256") >/dev/null ||
	fail module-content-hash
echo "module_root=$module_root"
echo "module_count=$module_count"
echo "module_manifest_sha256=$module_manifest_sha256"
echo M1892_STAGE3_MODULE_INSTALL_PASS
