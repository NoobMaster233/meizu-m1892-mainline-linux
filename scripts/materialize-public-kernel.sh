#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

upstream=${1:-}
output=${2:-}
fail() { echo "M1892_PUBLIC_KERNEL_MATERIALIZE_FAIL: $*" >&2; exit 1; }
[ -d "$upstream" ] || fail missing-upstream-directory
[ -n "$output" ] || { echo "usage: $0 UPSTREAM_GIT_TREE NEW_OUTPUT_TREE" >&2; exit 2; }
[ ! -e "$output" ] || fail output-exists
for command in awk comm git install mkdir sha256sum sort; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
public_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
inputs=$public_root/src/kernel-inputs
allowlist=$public_root/src/kernel/K1_SOURCE_ALLOWLIST.sha256
map=$public_root/src/kernel/K1_PACKAGE_MAP.tsv
[ -r "$allowlist" ] || fail missing-allowlist
[ -r "$map" ] || fail missing-package-map
expected_commit=85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8
git -C "$upstream" cat-file -e "$expected_commit^{commit}" || fail missing-upstream-commit

awk '!/^#/ && NF {print $2}' "$allowlist" | LC_ALL=C sort >"${TMPDIR:-/tmp}/m1892-allow.$$"
awk -F '\t' '!/^#/ && NF {print $2}' "$map" | LC_ALL=C sort >"${TMPDIR:-/tmp}/m1892-map.$$"
cleanup_lists() { rm -f "${TMPDIR:-/tmp}/m1892-allow.$$" "${TMPDIR:-/tmp}/m1892-map.$$"; }
trap cleanup_lists EXIT HUP INT TERM
comm -3 "${TMPDIR:-/tmp}/m1892-allow.$$" "${TMPDIR:-/tmp}/m1892-map.$$" |
	grep -q . && fail map-allowlist-mismatch

while read -r expected path; do
	case $expected in \#*|'') continue ;; esac
	file=$inputs/$path
	[ -f "$file" ] || fail "missing-input:$path"
	actual=$(sha256sum "$file" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "input-hash:$path:$actual"
done <"$allowlist"

git clone --no-checkout --quiet "$upstream" "$output"
git -C "$output" checkout --detach --quiet "$expected_commit"
mkdir -p "$output/.m1892"

tab=$(printf '\t')
while IFS="$tab" read -r operation source target; do
	case $operation in \#*|'') continue ;; esac
	input=$inputs/$source
	case $operation in
		install)
			install -m 0644 "$input" "$output/.m1892/config.base"
			;;
		merge-config)
			install -m 0644 "$input" "$output/.m1892/config.fragment"
			;;
		apply)
			git -C "$output" apply --check "$input" || fail "patch-check:$source"
			git -C "$output" apply "$input"
			;;
		copy)
			install -D -m 0644 "$input" "$output/$target"
			;;
		*) fail "unsupported-operation:$operation" ;;
	esac
done <"$map"

[ -r "$output/.m1892/config.base" ] || fail missing-base-config
[ -r "$output/.m1892/config.fragment" ] || fail missing-config-fragment
# Ordinary Phosh DPMS blanking hard-resets M1892 if the Qualcomm DSI PHY is
# allowed to runtime-suspend. Keep an explicit semantic gate in addition to
# the map/allowlist equality check so a packaging refactor cannot silently
# reintroduce the failure.
grep -Fq 'pm_runtime_forbid(dev);' \
	"$output/drivers/gpu/drm/msm/dsi/phy/dsi_phy.c" ||
	fail missing-m1892-dsi-phy-runtime-forbid
grep -Fq 'cfg80211_chandef_primary(chandef,' \
	"$output/drivers/net/wireless/ath/ath10k/mac.c" ||
	fail missing-m1892-ath10k-160-to-80
grep -Fq 'of_machine_is_compatible("meizu,m1892")' \
	"$output/drivers/net/wireless/ath/ath10k/mac.c" ||
	fail missing-m1892-ath10k-machine-gate
grep -Fq 'ufs_qcom_link_startup_post_change' \
	"$output/drivers/ufs/host/ufs-qcom.c" ||
	fail missing-m1892-ufs-ah8-clock-request
grep -Fq '#define UFS_HW_CLK_CTRL_EN' \
	"$output/drivers/ufs/host/ufs-qcom.h" ||
	fail missing-m1892-ufs-ah8-clock-mask
grep -Fq 'M1892 7.1-rc1: delayed invalid object in rcu_free_sheaf().' \
	"$output/mm/slab_common.c" || fail missing-m1892-kfree-rcu-sheaf-bypass
grep -Fq 'use_single_read = true' \
	"$output/sound/soc/codecs/cs35l41-lib.c" ||
	fail missing-m1892-cs35l41-single-read
grep -Fq 'of_machine_is_compatible("meizu,m1892")' \
	"$output/sound/soc/codecs/cs35l41-lib.c" ||
	fail missing-m1892-cs35l41-safe-powerdown
grep -Fq 'CS35L41_CLKID_SCLK' \
	"$output/sound/soc/qcom/sdm845.c" ||
	fail missing-m1892-sdm845-speaker-clock
grep -Fq '.prepare = q6voice_dai_prepare' \
	"$output/sound/soc/qcom/qdsp6/q6voice-dai.c" ||
	fail missing-m1892-q6voice-prepare-lifecycle
grep -Fq 'ret = 0;' "$output/sound/soc/qcom/qdsp6/q6voice.c" ||
	fail missing-m1892-q6voice-idempotent-prepare
grep -Fq 'qcom,pmi8998-typec' \
	"$output/drivers/usb/typec/tcpm/qcom/qcom_pmic_typec.c" ||
	fail missing-m1892-pmi8998-typec-match
grep -Fq 'PMI8998 hardware CC attached to TCPM' \
	"$output/drivers/usb/typec/tcpm/qcom/qcom_pmi8998_typec_port.c" ||
	fail missing-m1892-pmi8998-cc-driver
grep -Fq 'PMI8998 OTG VBUS ready; default off, maximum 500mA' \
	"$output/drivers/regulator/qcom_usb_vbus-regulator.c" ||
	fail missing-m1892-pmi8998-bounded-vbus
grep -Fq 'config INPUT_M1892_DW7914' \
	"$output/drivers/input/misc/Kconfig" || fail missing-m1892-dw7914-kconfig
grep -Fq 'DW7914_STANDARD_FF' \
	"$output/drivers/input/misc/m1892-dw7914-bounded-ff.c" ||
	fail missing-m1892-dw7914-product-wrapper
grep -Fq 'DW7914_M1892_SAFE_PULSE_MS      20' \
	"$output/drivers/input/misc/m1892-dw7914-safe-pulse.c" ||
	fail missing-m1892-dw7914-bounded-cutoff
grep -Fq '"qcom/m1892/dw_172hz.bin"' \
	"$output/drivers/input/misc/m1892-dw7914-safe-pulse.c" ||
	fail missing-m1892-dw7914-packaged-firmware-path
printf 'upstream_commit=%s\n' "$expected_commit" >"$output/.m1892/MATERIALIZATION.txt"
printf 'allowlist_sha256=%s\n' "$(sha256sum "$allowlist" | awk '{print $1}')" >>"$output/.m1892/MATERIALIZATION.txt"
printf 'package_map_sha256=%s\n' "$(sha256sum "$map" | awk '{print $1}')" >>"$output/.m1892/MATERIALIZATION.txt"
echo M1892_PUBLIC_KERNEL_MATERIALIZE_PASS
