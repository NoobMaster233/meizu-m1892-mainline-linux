#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

# Normalize overlay-allocated phandles to the physically accepted R527/R545
# flattened-DT ABI.  Phandles are opaque to conforming Linux drivers, but R555
# proved that an otherwise semantically equal, automatically allocated tree did
# not cross this device's firmware-to-initramfs boundary.  Keep this transform
# explicit, fail closed if the composition order changes, and verify references
# after every rewrite.
dtb=${1:-}
fail() { echo "M1892_PRODUCT_DTB_CANONICALIZE_FAIL: $*" >&2; exit 1; }
[ -f "$dtb" ] || fail missing-dtb
for command in fdtget fdtput; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

expect_hex()
{
	path=$1 property=$2 expected=$3
	actual=$(fdtget -t x "$dtb" "$path" "$property") ||
		fail "missing:$path:$property"
	[ "$actual" = "$expected" ] ||
		fail "unexpected:$path:$property:$actual"
}
put_hex()
{
	path=$1 property=$2
	shift 2
	fdtput -t x "$dtb" "$path" "$property" "$@"
}

expect_hex /reserved-memory/ipa-fw@8c400000 phandle 1101
expect_hex /soc@0/ipa@1e40000 memory-region 1000
expect_hex /soc@0/geniqup@ac0000/i2c@a88000/charger@c phandle 1102
expect_hex /soc@0/spmi@c440000/pmic@2/usb-vbus-regulator@1100 phandle 1103
expect_hex /otg-vbus-output phandle 1104
expect_hex /soc@0/spmi@c440000/pmic@2/typec@1300 phandle 1105
expect_hex /soc@0/pinctrl@3400000/qup-spi0-r447-cs1-state phandle 1106
expect_hex /regulator-audio-vsys-r447 phandle 1107
expect_hex /soc@0/pinctrl@3400000/quat-mi2s-r447-active-state phandle 1108
expect_hex /soc@0/pinctrl@3400000/quat-mi2s-r447-sd2-active-state phandle 1109
expect_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@0 phandle 110a
expect_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@1 phandle 110b
expect_hex /reserved-memory/m1892-removed-tail@8a900000 phandle 110c
expect_hex /remoteproc-adsp/glink-edge/apr/service@7/dais phandle f7
expect_hex /sound/mm2-dai-link/cpu sound-dai 'f7 1'
expect_hex /remoteproc-adsp/glink-edge/apr/apr-service@9/dais phandle 110d
expect_hex /sound/m1892-voicemmode1-dai-link/cpu sound-dai '110d 1'

put_hex /reserved-memory/ipa-fw@8c400000 phandle 1000
put_hex /soc@0/ipa@1e40000 memory-region 1000
put_hex /soc@0/geniqup@ac0000/i2c@a88000/charger@c phandle 1001
put_hex /soc@0/spmi@c440000/pmic@2/usb-vbus-regulator@1100 phandle 1002
put_hex /soc@0/spmi@c440000/pmic@2/typec@1300 vdd-vbus-supply 1002
put_hex /otg-vbus-output vout-supply 1002
put_hex /otg-vbus-output phandle 1003
put_hex /soc@0/spmi@c440000/pmic@2/typec@1300 phandle 1004
put_hex /soc@0/pinctrl@3400000/qup-spi0-r447-cs1-state phandle 1005
put_hex /soc@0/geniqup@8c0000/spi@880000 pinctrl-0 3f 1005
put_hex /regulator-audio-vsys-r447 phandle 1006
put_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@0 VP-supply 1006
put_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@1 VP-supply 1006
put_hex /soc@0/pinctrl@3400000/quat-mi2s-r447-active-state phandle 1007
put_hex /soc@0/pinctrl@3400000/quat-mi2s-r447-sd2-active-state phandle 1008
put_hex /sound pinctrl-0 1007 1008
put_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@0 phandle 1009
put_hex /soc@0/geniqup@8c0000/spi@880000/speaker-amp@1 phandle 100a
put_hex /sound/m1892-r447-speaker-dai-link/codec sound-dai 1009 0 100a 0
put_hex /reserved-memory/m1892-removed-tail@8a900000 phandle 100b
put_hex /remoteproc-adsp/glink-edge/apr/apr-service@9/dais phandle 100c
put_hex /sound/m1892-voicemmode1-dai-link/cpu sound-dai 100c 1

# Match the accepted flattened-property order as well.  fdtput prepends new
# properties, so write each group in reverse of its audited runtime order.
haptic=/soc@0/geniqup@ac0000/i2c@a90000/haptic@59
for property in compatible reg enable-gpios; do
	fdtput -d "$dtb" "$haptic" "$property"
done
put_hex "$haptic" enable-gpios 4e 2c 0
put_hex "$haptic" reg 59
fdtput -t s "$dtb" "$haptic" compatible dongwoon,dw7914-r259
ipa=/soc@0/ipa@1e40000
for property in firmware-name qcom,gsi-loader memory-region; do
	fdtput -d "$dtb" "$ipa" "$property"
done
fdtput -t s "$dtb" "$ipa" qcom,gsi-loader self
fdtput -t s "$dtb" "$ipa" firmware-name qcom/sdm845/m1892/ipa_fws.mdt
put_hex "$ipa" memory-region 1000

# R527 removed the development Bluetooth address from an already compiled
# tree.  The public source carries only an all-zero layout placeholder at the
# same source location.  Require that safe value and delete it here so no
# fixed identity is present in the distributable DTB.
bluetooth=/soc@0/geniqup@8c0000/serial@898000/bluetooth
[ "$(fdtget -t bx "$dtb" "$bluetooth" local-bd-address)" = \
	'0 0 0 0 0 0' ] || fail unsafe-bluetooth-address-placeholder
fdtput -d "$dtb" "$bluetooth" local-bd-address
if fdtget "$dtb" "$bluetooth" local-bd-address >/dev/null 2>&1; then
	fail fixed-bluetooth-address
fi

expect_hex /reserved-memory/ipa-fw@8c400000 phandle 1000
expect_hex /soc@0/ipa@1e40000 memory-region 1000
expect_hex /soc@0/geniqup@8c0000/spi@880000 pinctrl-0 '3f 1005'
expect_hex /sound pinctrl-0 '1007 1008'
expect_hex /sound/m1892-r447-speaker-dai-link/codec sound-dai '1009 0 100a 0'
expect_hex /remoteproc-adsp/glink-edge/apr/service@7/dais phandle f7
expect_hex /sound/mm2-dai-link/cpu sound-dai 'f7 1'
expect_hex /remoteproc-adsp/glink-edge/apr/apr-service@9/dais phandle 100c
expect_hex /sound/m1892-voicemmode1-dai-link/cpu sound-dai '100c 1'
echo M1892_PRODUCT_DTB_CANONICALIZE_PASS
