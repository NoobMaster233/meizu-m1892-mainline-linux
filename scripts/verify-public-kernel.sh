#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

output=${1:-}
fail() { echo "M1892_PUBLIC_KERNEL_VERIFY_FAIL: $*" >&2; exit 1; }
[ -d "$output" ] || fail missing-output-directory
for command in fdtget grep modinfo sha256sum; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

kernel=$output/arch/arm64/boot/Image.gz
dtb=$output/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb
panel=$output/drivers/gpu/drm/panel/panel-samsung-sofef00m.ko
cs_dsp=$output/drivers/firmware/cirrus/cs_dsp.ko
wm_adsp=$output/sound/soc/codecs/snd-soc-wm-adsp.ko
cs35l41_lib=$output/sound/soc/codecs/snd-soc-cs35l41-lib.ko
cs35l41=$output/sound/soc/codecs/snd-soc-cs35l41.ko
cs35l41_spi=$output/sound/soc/codecs/snd-soc-cs35l41-spi.ko
sdm845_audio=$output/sound/soc/qcom/snd-soc-sdm845.ko
system_map=$output/System.map
manifest=$output/M1892-KERNEL-BUILD-MANIFEST.txt
[ -f "$kernel" ] || fail missing-kernel
[ -f "$dtb" ] || fail missing-dtb
[ -f "$panel" ] || fail missing-panel-module
for module in "$cs_dsp" "$wm_adsp" "$cs35l41_lib" "$cs35l41" \
	"$cs35l41_spi" "$sdm845_audio"; do
	[ -f "$module" ] || fail "missing-speaker-module:$module"
done
[ -f "$system_map" ] || fail missing-system-map
[ -f "$manifest" ] || fail missing-build-manifest
manifest_value()
{
	key=$1
	awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); found++ }
		END { if (found != 1) exit 1 }' "$manifest"
}
for spec in \
	"kernel_sha256:$kernel" \
	"dtb_sha256:$dtb" \
	"panel_sha256:$panel" \
	"cs_dsp_sha256:$cs_dsp" \
	"wm_adsp_sha256:$wm_adsp" \
	"cs35l41_lib_sha256:$cs35l41_lib" \
	"cs35l41_sha256:$cs35l41" \
	"cs35l41_spi_sha256:$cs35l41_spi" \
	"sdm845_audio_sha256:$sdm845_audio" \
	"system_map_sha256:$system_map"; do
	key=${spec%%:*}
	file=${spec#*:}
	expected=$(manifest_value "$key") || fail "manifest-key:$key"
	actual=$(sha256sum "$file" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "manifest-hash:$key:$actual"
done
# Image.gz, modules and System.map include compiler/binutils-dependent bytes.
# Record their hashes below, but do not compare them with a different host's
# output. The canonical DTB is data-only and must remain byte-identical. The
# remaining checks enforce the kernel's ABI, configuration, symbols and device
# contract instead of silently weakening validation.
dtb_sha256=$(sha256sum "$dtb" | awk '{print $1}')
[ "$dtb_sha256" = 4e09e9aaac03503bd9c76afa7c1b602bad43227b6d96bd15f7abef5ac02244f4 ] ||
	fail "dtb-hash:$dtb_sha256"
[ "$(modinfo -F vermagic "$panel")" = \
	'7.1.0-rc1-sdm845 SMP preempt mod_unload aarch64' ] || fail panel-vermagic
for module in "$cs_dsp" "$wm_adsp" "$cs35l41_lib" "$cs35l41" \
	"$cs35l41_spi" "$sdm845_audio"; do
	[ "$(modinfo -F vermagic "$module")" = \
		'7.1.0-rc1-sdm845 SMP preempt mod_unload aarch64' ] ||
		fail "speaker-vermagic:$module"
done
[ "$(fdtget -t s "$dtb" / model)" = 'Meizu 16th Plus (M1892)' ] || fail dt-model
bluetooth=/soc@0/geniqup@8c0000/serial@898000/bluetooth
if fdtget "$dtb" "$bluetooth" local-bd-address >/dev/null 2>&1; then
	fail fixed-bluetooth-address
fi
[ "$(fdtget -t s "$dtb" /soc@0/video-codec@aa00000 status)" = okay ] ||
	fail dt-venus
[ "$(fdtget -t s "$dtb" /soc@0/ipa@1e40000 status)" = okay ] || fail dt-ipa
[ "$(fdtget -t s "$dtb" /soc@0/ipa@1e40000 qcom,gsi-loader)" = self ] ||
	fail dt-ipa-loader
ipa_fw=$(fdtget -t x "$dtb" /reserved-memory/ipa-fw@8c400000 phandle)
[ "$(fdtget -t x "$dtb" /soc@0/ipa@1e40000 memory-region)" = "$ipa_fw" ] ||
	fail dt-ipa-memory-region
[ "$(fdtget -t s "$dtb" /soc@0/usb@a6f8800/usb@a600000 dr_mode)" = host ] ||
	fail dt-usb-host
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/typec@1300 status)" = okay ] ||
	fail dt-typec
[ "$(fdtget -t s "$dtb" /soc@0/spmi@c440000/pmic@2/usb-vbus-regulator@1100 status)" = okay ] ||
	fail dt-vbus
[ "$(fdtget "$dtb" /battery constant-charge-current-max-microamp)" = 1950000 ] ||
	fail dt-charge-current
[ "$(fdtget -t s "$dtb" /soc@0/interconnect@17d41000 compatible)" = \
	'qcom,sdm845-osm-l3 qcom,osm-l3' ] || fail dt-osm-l3
[ "$(fdtget -t s "$dtb" /soc@0/cpufreq@17d43000 compatible)" = \
	'qcom,sdm845-cpufreq-hw qcom,cpufreq-hw' ] || fail dt-cpufreq-hw
[ "$(fdtget -t s "$dtb" /soc@0/geniqup@ac0000/i2c@a90000/haptic@59 compatible)" = dongwoon,dw7914-r259 ] ||
	fail dt-haptics
[ "$(fdtget -t s "$dtb" /sound status)" = okay ] || fail dt-sound
audio_routing=$(fdtget -t s "$dtb" /sound audio-routing) || fail dt-audio-routing
for route in 'RX_BIAS MCLK' 'MIC BIAS1 MCLK' 'MIC BIAS2 MCLK' \
	'MIC BIAS3 MCLK' 'AMIC1 MIC BIAS1' 'AMIC2 MIC BIAS2' \
	'AMIC3 MIC BIAS3'; do
	printf '%s\n' "$audio_routing" | grep -Fq "$route" ||
		fail "dt-audio-routing:$route"
done
for service in 9 a b; do
	[ "$(fdtget -t s "$dtb" "/remoteproc-adsp/glink-edge/apr/apr-service@$service" status)" = okay ] ||
		fail "dt-q6voice-service:$service"
done
[ "$(fdtget "$dtb" /remoteproc-adsp/glink-edge/apr/apr-service@9/dais/dai@1 reg)" = 1 ] ||
	fail dt-q6voice-dai
[ "$(fdtget -t s "$dtb" /sound/m1892-voicemmode1-dai-link link-name)" = VoiceMMode1 ] ||
	fail dt-voicemmode1-link
# The SDM845 machine driver walks sound-card children in flattened-tree order.
# A q6routing back end appearing before its required front end makes route
# creation fail with -ENODEV.  Gate the complete order, including the retained
# disabled bring-up nodes, instead of merely checking that each node exists.
expected_sound_nodes='m1892-voicemmode1-dai-link
m1892-r447-mm1-dai-link
m1892-r447-speaker-dai-link
mm1-dai-link
mm2-dai-link
slimcap-dai-link
slim6-dai-link'
[ "$(fdtget -l "$dtb" /sound)" = "$expected_sound_nodes" ] ||
	fail dt-sound-node-order
[ "$(fdtget -t s "$dtb" /sound/mm1-dai-link status)" = disabled ] ||
	fail dt-old-mm1-enabled
[ "$(fdtget -t s "$dtb" /sound/slim6-dai-link status)" = disabled ] ||
	fail dt-old-slim6-enabled
q6voice_provider=$(fdtget -t x "$dtb" /remoteproc-adsp/glink-edge/apr/apr-service@9/dais phandle)
[ "$(fdtget -t x "$dtb" /sound/m1892-voicemmode1-dai-link/cpu sound-dai)" = "$q6voice_provider 1" ] ||
	fail dt-voicemmode1-provider
for amp in speaker-amp@0 speaker-amp@1; do
	[ "$(fdtget -t s "$dtb" "/soc@0/geniqup@8c0000/spi@880000/$amp" compatible)" = cirrus,cs35l41 ] ||
		fail "dt-speaker:$amp"
done
fdtget "$dtb" /reserved-memory/m1892-removed-tail@8a900000 no-map >/dev/null ||
	fail dt-reserved-tail
[ "$(fdtget "$dtb" /soc@0/spmi@c440000/pmic@0/pon@800/resin linux,code)" = 114 ] ||
	fail dt-volume-down
for node in stm@6002000 funnel@6041000 funnel@6043000 funnel@6045000 \
	replicator@6046000 etf@6047000 etr@6048000 etm@7040000 etm@7140000 \
	etm@7240000 etm@7340000 etm@7440000 etm@7540000 etm@7640000 etm@7740000; do
	[ "$(fdtget -t s "$dtb" "/soc@0/$node" status)" = disabled ] ||
		fail "dt-coresight:$node"
done
grep -qx 'CONFIG_SCSI_UFS_QCOM=y' "$output/.config" || fail config-ufs
grep -qx 'CONFIG_ARM_QCOM_CPUFREQ_HW=y' "$output/.config" || fail config-cpufreq-hw
grep -qx 'CONFIG_INTERCONNECT_QCOM_OSM_L3=y' "$output/.config" || fail config-osm-l3
grep -qx 'CONFIG_USB_CONFIGFS_NCM=y' "$output/.config" || fail config-ncm
grep -qx 'CONFIG_DRM_PANEL_SAMSUNG_SOFEF00M=m' "$output/.config" || fail config-panel
grep -qx 'CONFIG_SYN_COOKIES=y' "$output/.config" || fail config-syn-cookies
grep -qx 'CONFIG_SND_SOC_QDSP6_Q6VOICE_DAI=m' "$output/.config" || fail config-q6voice-dai
grep -qx 'CONFIG_SND_SOC_QDSP6_Q6VOICE=m' "$output/.config" || fail config-q6voice
grep -qx 'CONFIG_SND_SOC_CS35L41_SPI=m' "$output/.config" || fail config-cs35l41-spi
# Docker is part of the phone's advertised userspace only when the kernel also
# carries the complete default-bridge/NAT closure.  Keep it built-in so a
# firmware-complete userdata cannot accidentally omit matching modules.
for option in \
	CONFIG_NF_CONNTRACK \
	CONFIG_NF_NAT \
	CONFIG_NF_TABLES \
	CONFIG_NF_TABLES_INET \
	CONFIG_NFT_CT \
	CONFIG_NFT_MASQ \
	CONFIG_NFT_NAT \
	CONFIG_NFT_REJECT \
	CONFIG_NFT_REJECT_INET \
	CONFIG_NFT_COMPAT \
	CONFIG_NETFILTER_XTABLES \
	CONFIG_NETFILTER_XT_NAT \
	CONFIG_NETFILTER_XT_TARGET_MASQUERADE \
	CONFIG_NETFILTER_XT_TARGET_REDIRECT \
	CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
	CONFIG_NETFILTER_XT_MATCH_CONNTRACK \
	CONFIG_NETFILTER_XT_MATCH_COMMENT \
	CONFIG_NETFILTER_XT_MATCH_MARK; do
	grep -qx "$option=y" "$output/.config" || fail "config-docker:${option#CONFIG_}"
done
grep -qx 'CONFIG_TYPEC_TCPM=y' "$output/.config" || fail config-tcpm-builtin
grep -qx 'CONFIG_TYPEC_QCOM_PMIC=y' "$output/.config" ||
	fail config-qcom-pmic-typec-builtin
grep -qx 'CONFIG_REGULATOR_QCOM_USB_VBUS=y' "$output/.config" ||
	fail config-qcom-usb-vbus-builtin
grep -qx 'CONFIG_INPUT_M1892_DW7914=y' "$output/.config" ||
	fail config-m1892-dw7914-builtin
grep -q ' qcom_pmi8998_typec_port_probe$' "$system_map" ||
	fail image-pmi8998-typec-driver
grep -q ' qcom_usb_vbus_regulator_probe$' "$system_map" ||
	fail image-pmi8998-vbus-driver
grep -q ' dw7914_probe$' "$system_map" || fail image-dw7914-driver

echo M1892_PUBLIC_KERNEL_VERIFY_PASS
sha256sum "$kernel" "$dtb" "$panel" "$system_map"
