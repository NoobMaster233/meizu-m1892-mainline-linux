#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_tree=${1:-}
output=${2:-}
jobs=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
fail() { echo "M1892_PUBLIC_KERNEL_BUILD_FAIL: $*" >&2; exit 1; }
[ -e "$source_tree/.git" ] || fail missing-materialized-source-tree
[ -r "$source_tree/.m1892/config.base" ] || fail missing-base-config
[ -r "$source_tree/.m1892/config.fragment" ] || fail missing-config-fragment
[ -n "$output" ] || { echo "usage: $0 MATERIALIZED_SOURCE_TREE NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
[ ! -e "$output" ] || fail output-exists
for command in aarch64-linux-gnu-gcc awk cp date dtc fdtget fdtput fdtoverlay \
	find getconf git make mkdir modinfo mv realpath sha256sum tail; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
source_tree=$(CDPATH='' cd -- "$source_tree" && pwd)
output=$(realpath -m "$output")
[ "$(git -C "$source_tree" rev-parse HEAD)" = 85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8 ] ||
	fail upstream-commit
aarch64-linux-gnu-gcc --version | head -n 1 |
	grep -q '11\.4\.0' || fail compiler-version

mkdir -p "$output"
mkdir -p "$output/.tmp"
# WSL may inherit TEMP/TMPDIR from Windows.  Keeping compiler temporaries in
# the new ext4 build directory avoids both nearly-full host drives and NTFS
# path/performance differences; GitHub Actions follows the identical rule.
export TMPDIR=$output/.tmp
cp "$source_tree/.m1892/config.base" "$output/.config"
ARCH=arm64 "$source_tree/scripts/kconfig/merge_config.sh" -m -O "$output" \
	"$output/.config" "$source_tree/.m1892/config.fragment" >/dev/null
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_USER=m1892 KBUILD_BUILD_HOST=k1-clean KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1778300477 KCONFIG_NOTIMESTAMP=1
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(LC_ALL=C TZ=UTC0 date -u -d "@$SOURCE_DATE_EPOCH" \
	'+%a %b %e %T UTC %Y')
# Out-of-tree DWARF otherwise records both temporary directories.  Those paths
# feed the two embedded VDSO build IDs even though the executable code and
# System.map are identical.  Kbuild's reproducible-build documentation requires
# both C and assembler prefix maps.
canonical_source=/usr/src/m1892-linux
canonical_output=/usr/src/m1892-linux-build
export KCFLAGS="-fdebug-prefix-map=$source_tree=$canonical_source -fdebug-prefix-map=$output=$canonical_output"
export KAFLAGS="$KCFLAGS"
make -C "$source_tree" O="$output" LOCALVERSION= olddefconfig >/dev/null
kernel_release=$(make -s -C "$source_tree" O="$output" LOCALVERSION= \
	kernelrelease | tail -n 1)
[ "$kernel_release" = 7.1.0-rc1-sdm845 ] ||
	fail "kernel-release:$kernel_release"

# Build the kernel and the complete configured module dependency graph in one
# Kbuild invocation.  Building selected .ko targets one by one runs modpost on
# an incomplete symbol graph (for example wm_adsp cannot see cs_dsp and ASoC),
# which can either fail or produce an unusable partial module set.  The release
# archive below still contains only the explicitly audited M1892 modules.
make -C "$source_tree" O="$output" LOCALVERSION= -j"$jobs" \
	qcom/sdm845-meizu-m1892-r159-product.dtb
make -C "$source_tree" O="$output" LOCALVERSION= -j"$jobs" \
	Image.gz modules

kernel=$output/arch/arm64/boot/Image.gz
base_dtb=$output/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-r159-product.dtb
dtb=$output/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb
panel=$output/drivers/gpu/drm/panel/panel-samsung-sofef00m.ko
cs_dsp=$output/drivers/firmware/cirrus/cs_dsp.ko
wm_adsp=$output/sound/soc/codecs/snd-soc-wm-adsp.ko
cs35l41_lib=$output/sound/soc/codecs/snd-soc-cs35l41-lib.ko
cs35l41=$output/sound/soc/codecs/snd-soc-cs35l41.ko
cs35l41_spi=$output/sound/soc/codecs/snd-soc-cs35l41-spi.ko
sdm845_audio=$output/sound/soc/qcom/snd-soc-sdm845.ko
overlay_dir=$source_tree/.m1892/dtb-overlays
overlay_work=$output/.m1892-dtb-overlays
mkdir -p "$overlay_work"
cp "$base_dtb" "$dtb"
for name in \
	sdm845-meizu-m1892-current-haptics \
	sdm845-meizu-m1892-r306-venus-enable \
	sdm845-meizu-m1892-r350-ipa-enable \
	sdm845-meizu-m1892-r368-disable-coresight \
	sdm845-meizu-m1892-r400-smb2-1950ma \
	sdm845-meizu-m1892-r401-i2c10-passive \
	sdm845-meizu-m1892-r402-smb1355-telemetry \
	sdm845-meizu-m1892-r403-usb-host-sink-xpad \
	sdm845-meizu-m1892-r404-pmi8998-otg-vbus \
	sdm845-meizu-m1892-r407-pmi8998-source-pd \
	sdm845-meizu-m1892-r408-pmi8998-sinking-host \
	sdm845-meizu-m1892-r409-pmi8998-sinking-host-op \
	sdm845-meizu-m1892-r447-cs35l41-sd2-muted \
	sdm845-meizu-m1892-r438-speaker-routes \
	sdm845-meizu-m1892-r470-reserve-removed-tail \
	sdm845-meizu-m1892-r495-volume-down \
	sdm845-meizu-m1892-voice-call; do
	dtc -q -I dts -O dtb -@ -o "$overlay_work/$name.dtbo" \
		"$overlay_dir/$name.dtso"
	fdtoverlay -i "$dtb" -o "$overlay_work/next.dtb" \
		"$overlay_work/$name.dtbo"
	mv "$overlay_work/next.dtb" "$dtb"
done
sh "$source_tree/.m1892/canonicalize-m1892-current-product-dtb.sh" "$dtb"

kernel_sha256=$(sha256sum "$kernel" | awk '{print $1}')
dtb_sha256=$(sha256sum "$dtb" | awk '{print $1}')
panel_sha256=$(sha256sum "$panel" | awk '{print $1}')
cs_dsp_sha256=$(sha256sum "$cs_dsp" | awk '{print $1}')
wm_adsp_sha256=$(sha256sum "$wm_adsp" | awk '{print $1}')
cs35l41_lib_sha256=$(sha256sum "$cs35l41_lib" | awk '{print $1}')
cs35l41_sha256=$(sha256sum "$cs35l41" | awk '{print $1}')
cs35l41_spi_sha256=$(sha256sum "$cs35l41_spi" | awk '{print $1}')
sdm845_audio_sha256=$(sha256sum "$sdm845_audio" | awk '{print $1}')
system_map_sha256=$(sha256sum "$output/System.map" | awk '{print $1}')

cat >"$output/M1892-KERNEL-BUILD-MANIFEST.txt" <<EOF
format=m1892-public-k1-v1
upstream_commit=85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8
compiler=aarch64-linux-gnu-gcc-11.4.0
kernel_sha256=$kernel_sha256
dtb_sha256=$dtb_sha256
panel_sha256=$panel_sha256
cs_dsp_sha256=$cs_dsp_sha256
wm_adsp_sha256=$wm_adsp_sha256
cs35l41_lib_sha256=$cs35l41_lib_sha256
cs35l41_sha256=$cs35l41_sha256
cs35l41_spi_sha256=$cs35l41_spi_sha256
sdm845_audio_sha256=$sdm845_audio_sha256
system_map_sha256=$system_map_sha256
fixed_bluetooth_address=absent
EOF
"$(dirname -- "$0")/verify-public-kernel.sh" "$output"
echo M1892_PUBLIC_KERNEL_BUILD_PASS
cat "$output/M1892-KERNEL-BUILD-MANIFEST.txt"
