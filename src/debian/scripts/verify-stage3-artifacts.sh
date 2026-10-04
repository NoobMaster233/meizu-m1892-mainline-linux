#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_recovery=${1:-}
recovery=${2:-}
rootfs=${3:-}
evidence_dir=${4:-}
[ -f "$source_recovery" ] && [ -f "$recovery" ] && [ -f "$rootfs" ] && \
	[ -n "$evidence_dir" ] || {
	echo "usage: $0 SOURCE_RECOVERY STAGE3_RECOVERY ROOTFS_EXT4_GZ EVIDENCE_DIR" >&2
	exit 2
}
fail() { echo "M1892_DEBIAN_STAGE3_ARTIFACT_VERIFY_FAIL: $*" >&2; exit 1; }
command -v strings >/dev/null 2>&1 || fail missing-command:strings
[ "$(stat -c %s "$source_recovery")" = 67108864 ] || fail source-size
[ "$(stat -c %s "$recovery")" = 67108864 ] || fail recovery-size
[ -f "$rootfs.sha256" ] || fail rootfs-sidecar
(cd "$(dirname -- "$rootfs")" && sha256sum -c "$(basename -- "$rootfs").sha256") >/dev/null || fail rootfs-hash
rootfs_sha=$(awk 'NR == 1 { print $1 }' "$rootfs.sha256")
recovery_metadata=$(dirname -- "$recovery")/BUILD-METADATA.txt
[ -r "$recovery_metadata" ] || fail recovery-metadata-absent
[ "$(sed -n 's/^rootfs_sha256=//p' "$recovery_metadata")" = "$rootfs_sha" ] ||
	fail recovery-rootfs-hash-binding
[ "$(sed -n 's/^rootfs_size=//p' "$recovery_metadata")" = \
	"$(stat -c %s "$rootfs")" ] || fail recovery-rootfs-size-binding
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
# shellcheck disable=SC1090
. "$tree_dir/config/stage3.env"
mss_extractor_sha=091ed1ef39ac0f458b6787df3f1ff8834ad9a97652b8dca7d4b899303ea7a893
[ "$(sha256sum "$source_recovery" | awk '{print $1}')" = \
	"$M1892_STAGE3_SOURCE_RECOVERY_SHA256" ] || fail source-hash

work=$(mktemp -d /tmp/m1892-debian-stage3-artifact-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/rootfs" "$work/initramfs" "$evidence_dir"
dd if="$source_recovery" of="$work/source-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
dd if="$recovery" of="$work/output-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
cmp -s "$work/source-tail" "$work/output-tail" || fail stock-tail-changed

python3 - "$recovery" "$work" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if raw[:8] != b'ANDROID!': raise SystemExit('outer-magic')
oks, ors, ops = (struct.unpack_from('<I', raw, off)[0] for off in (8, 16, 36))
oro = ops + ((oks + ops - 1) // ops) * ops
inner = raw[oro:oro + ors]
if inner[:8] != b'ANDROID!': raise SystemExit('inner-magic')
iks, irs, ips = (struct.unpack_from('<I', inner, off)[0] for off in (8, 16, 36))
iro = ips + ((iks + ips - 1) // ips) * ips
cmd = inner[64:576].split(b'\0', 1)[0] + inner[608:1632].split(b'\0', 1)[0]
open(sys.argv[2] + '/initramfs.gz', 'wb').write(inner[iro:iro + irs])
open(sys.argv[2] + '/cmdline', 'wb').write(cmd)
open(sys.argv[2] + '/kernel-dtb', 'wb').write(inner[ips:ips + iks])
PY
case $(cat "$work/cmdline") in *'m1892.usb=acm-ncm'*) ;; *) fail usb-cmdline ;; esac
kernel_mode=$(sed -n 's/^kernel_mode=//p' "$recovery_metadata")
case "$kernel_mode" in
	source-r545)
		[ "$(sha256sum "$work/kernel-dtb" | awk '{print $1}')" = \
			b9b95bc1df5681cb492f131e91dadada666e6bf8e7eb1d9561baaf8caf91d424 ] ||
			fail source-kernel-dtb-hash
		;;
	public-clean)
		python3 - "$work/kernel-dtb" "$work/kernel-image.gz" "$work/kernel.dtb" <<'PY'
import struct, sys
blob = open(sys.argv[1], 'rb').read()
hits = []
start = 0
while True:
    pos = blob.find(b'\xd0\x0d\xfe\xed', start)
    if pos < 0:
        break
    if pos + 8 <= len(blob):
        size = struct.unpack_from('>I', blob, pos + 4)[0]
        if 40 <= size <= len(blob) - pos:
            hits.append((pos, size))
    start = pos + 1
if len(hits) != 1:
    raise SystemExit('unexpected-dtb-count')
pos, size = hits[0]
open(sys.argv[2], 'wb').write(blob[:pos])
open(sys.argv[3], 'wb').write(blob[pos:pos + size])
PY
		[ "$(sha256sum "$work/kernel-image.gz" | awk '{print $1}')" = \
			"$(sed -n 's/^kernel_image_sha256=//p' "$recovery_metadata")" ] ||
			fail public-kernel-image-hash
		[ "$(sha256sum "$work/kernel.dtb" | awk '{print $1}')" = \
			"$(sed -n 's/^kernel_dtb_sha256=//p' "$recovery_metadata")" ] ||
			fail public-kernel-dtb-hash
		;;
	*) fail invalid-kernel-mode ;;
esac
gzip -dc "$work/initramfs.gz" >"$work/initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/initramfs.cpio")
init=$work/initramfs/init
[ -x "$init" ] || fail init-absent
provider=$work/initramfs/bin/m1892-display-auto-r59
[ -x "$provider" ] || fail provider-absent
provider_mode=$(sed -n 's/^provider_mode=//p' "$recovery_metadata")
case "$provider_mode" in
	source-r545-external-haptics)
		grep -Fq 'haptic_modules=/lib/modules/m1892-haptics' "$provider" ||
			fail source-provider-haptics-absent
		;;
	public-built-in-haptics)
		grep -Fq 'cat "$haptic/safety"' "$provider" ||
			fail public-provider-haptic-safety-absent
		if grep -Fq 'haptic_modules=' "$provider"; then
			fail public-provider-external-haptics
		fi
		;;
	*) fail invalid-provider-mode ;;
esac
grep -Fq 'm1892-debian13-stage3-rootfs.ext4.gz' "$init" || fail wrong-init
grep -Fq "expected_bytes=$(stat -c %s "$rootfs")" "$init" || fail rootfs-size-contract
grep -Fq "expected_sha256=$rootfs_sha" "$init" || fail rootfs-hash-contract
metadata=$(dirname -- "$rootfs")/BUILD-METADATA.txt
[ -r "$metadata" ] || fail rootfs-metadata-absent
image_bytes=$(sed -n 's/^persistent_root_image_size=//p' "$metadata")
image_sha=$(sed -n 's/^persistent_root_image_sha256=//p' "$metadata")
grep -Fq "expected_image_bytes=$image_bytes" "$init" || fail root-image-size-contract
grep -Fq "expected_image_sha256=$image_sha" "$init" || fail root-image-hash-contract
grep -Fq 'size=6144m tmpfs /run' "$init" || fail ram-budget-contract-absent
grep -Fq 'rm -f "$archive" "$ready"' "$init" || fail compressed-copy-release-absent
grep -Fq 'rootfs_id=m1892-debian13-stage3-ram' "$init" || fail stage3-identity-gate-absent
grep -Fq 'exec switch_root -c /dev/console "$newroot" /sbin/init' "$init" || fail switch-root-absent
if grep -Eq 'mount[^\n]*/dev/sda19|mkfs|resize2fs|e2fsck' "$init"; then fail persistent-storage-command; fi

gzip -dc "$rootfs" >"$work/rootfs.ext4"
[ "$(stat -c %s "$work/rootfs.ext4")" = "$image_bytes" ] || fail root-image-size
[ "$(sha256sum "$work/rootfs.ext4" | awk '{print $1}')" = "$image_sha" ] || fail root-image-hash
e2fsck -fn "$work/rootfs.ext4" >"$evidence_dir/e2fsck.log" 2>&1 || fail rootfs-e2fsck
[ "$(blkid -s TYPE -o value "$work/rootfs.ext4")" = ext4 ] || fail rootfs-not-ext4
[ "$(blkid -s LABEL -o value "$work/rootfs.ext4")" = M1892_DEB13_S3 ] || fail rootfs-label
debugfs -R "rdump / $work/rootfs" "$work/rootfs.ext4" >/dev/null 2>&1 || fail rootfs-extract
fs_owner()
{
	debugfs -R "stat $1" "$work/rootfs.ext4" 2>/dev/null |
		awk '/^User:/ { print $2 ":" $4; exit }'
}
for path in /etc /usr /usr/lib /var /var/lib /var/log; do
	[ "$(fs_owner "$path")" = 0:0 ] || fail "unsafe-owner:$path"
done
grep -Fxq 'rootfs_id=m1892-debian13-stage3-ram' "$work/rootfs/etc/m1892-rootfs-identity" || fail rootfs-identity
grep -Fxq 'suspend_policy=masked' "$work/rootfs/etc/m1892-rootfs-identity" || fail suspend-policy
cmp -s "$work/rootfs/etc/xdg/powerdevilrc" \
	"$(dirname "$0")/../rootfs-overlay/etc/xdg/powerdevilrc" ||
	fail powerdevil-manual-policy-content
[ "$(grep -Fxc 'AutoSuspendAction=0' "$work/rootfs/etc/xdg/powerdevilrc")" = 3 ] ||
	fail powerdevil-manual-policy-count
grep -Eq '^m1892-live:x:1000:1000:' "$work/rootfs/etc/passwd" || fail recovery-live-user-absent
grep -Eq '^m1892-live:!\*:20703:' "$work/rootfs/etc/shadow" || fail recovery-live-user-shadow-policy
grep -Fxq 'User=m1892-live' "$work/rootfs/etc/sddm.conf.d/90-m1892-stage3-live.conf" || fail sddm-user
grep -Fxq 'Session=plasma-mobile.desktop' "$work/rootfs/etc/sddm.conf.d/90-m1892-stage3-live.conf" || fail sddm-session
grep -Fxq 'Autolock=false' "$work/rootfs/home/m1892-live/.config/kscreenlockerrc" ||
	fail live-autolock-policy
grep -Fxq 'LockOnResume=false' "$work/rootfs/home/m1892-live/.config/kscreenlockerrc" ||
	fail live-resume-lock-policy
[ "$(grep -Fxc 'LockBeforeTurnOffDisplay=false' \
	"$work/rootfs/home/m1892-live/.config/powerdevilrc")" = 3 ] ||
	fail live-dpms-lock-policy
for group in '[AC][Display]' '[Battery][Display]' '[LowBattery][Display]'; do
	grep -Fxq "$group" "$work/rootfs/home/m1892-live/.config/powerdevilrc" ||
		fail "live-dpms-profile:$group"
done
grep -Fxq 'Enabled=false' "$work/rootfs/home/m1892-live/.config/kwalletrc" ||
	fail live-wallet-policy
grep -Fxq 'First Use=false' "$work/rootfs/home/m1892-live/.config/kwalletrc" ||
	fail live-wallet-first-use-policy
grep -Fxq 'disabledQuickSettings=org.kde.plasma.quicksetting.record' \
	"$work/rootfs/etc/xdg/plasmamobilerc" ||
	fail live-quick-settings-policy
for blacklist_file in \
	"$work/rootfs/etc/skel/.config/applications-blacklistrc" \
	"$work/rootfs/home/m1892-live/.config/applications-blacklistrc"; do
	grep -Fxq '[Applications]' "$blacklist_file" ||
		fail plasma-mobile-application-blacklist-group
	blacklist=$(sed -n 's/^blacklist=//p' "$blacklist_file")
	for entry in systemsettings kdesystemsettings; do
		printf '%s\n' "$blacklist" | tr ',' '\n' | grep -Fxq "$entry" ||
			fail "plasma-mobile-application-blacklist:$entry"
	done
	printf '%s\n' "$blacklist" | tr ',' '\n' |
		grep -Fxq org.kde.mobile.plasmasettings &&
		fail plasma-mobile-settings-blacklisted
done
for file in "$work/rootfs/etc/skel/.config/kglobalshortcutsrc" \
	"$work/rootfs/home/m1892-live/.config/kglobalshortcutsrc"; do
	grep -Fxq 'PowerOff=Power Off,none,Power Off' "$file" || fail power-key-toggle-shortcut
	grep -Fxq 'Turn Off Screen=none,Power Off,Turn Off Screen' "$file" ||
		fail power-key-one-way-shortcut-disabled
done
for file in "$work/rootfs/etc/skel/.config/kwinrulesrc" \
	"$work/rootfs/home/m1892-live/.config/kwinrulesrc"; do
	grep -Fxq 'wmclass=gamescope' "$file" || fail gamescope-fullscreen-window-class
	grep -Fxq 'wmclassmatch=1' "$file" || fail gamescope-fullscreen-window-match
	grep -Fxq 'fullscreen=true' "$file" || fail gamescope-fullscreen-enabled
	grep -Fxq 'fullscreenrule=3' "$file" || fail gamescope-fullscreen-force-rule
	grep -Fxq 'rules=1' "$file" || fail gamescope-fullscreen-rule-list
done
[ "$(readlink "$work/rootfs/usr/share/icons/hicolor/scalable/apps/preferences-system.svg")" = \
	../../../breeze/apps/48/systemsettings.svg ] || fail system-settings-icon-alias
[ -f "$work/rootfs/usr/lib/aarch64-linux-gnu/qt6/plugins/imageformats/libqsvg.so" ] ||
	fail qt6-svg-imageformat-plugin
[ -f "$work/rootfs/usr/lib/aarch64-linux-gnu/qt5/plugins/imageformats/libqsvg.so" ] ||
	fail maliit-qt5-svg-imageformat-plugin
[ -f "$work/rootfs/usr/lib/aarch64-linux-gnu/libcanberra-0.30/libcanberra-pulse.so" ] ||
	fail canberra-pulse-driver
[ -f "$work/rootfs/usr/lib/tmpfiles.d/m1892-cpufreq-boost.conf" ] ||
	fail cpufreq-boost-policy-absent
grep -Fxq 'w /sys/devices/system/cpu/cpufreq/boost - - - - 1' \
	"$work/rootfs/usr/lib/tmpfiles.d/m1892-cpufreq-boost.conf" ||
	fail cpufreq-boost-policy-invalid
[ -x "$work/rootfs/usr/libexec/m1892/stage3-acceptance" ] || fail acceptance-absent
[ -x "$work/rootfs/usr/libexec/m1892/stage3-session-acceptance" ] || fail session-acceptance-absent
[ "$(sha256sum "$work/rootfs/usr/libexec/m1892/reboot-fastboot" | awk '{print $1}')" = \
	2b8eb06dcf71544e6ae7f189c37bd9bdd67c6f18e36d0fa44fa2e35814f989ba ] ||
	fail reboot-fastboot-hash
[ -f "$work/rootfs/etc/xdg/autostart/m1892-stage3-session-acceptance.desktop" ] || fail acceptance-autostart-absent
[ -L "$work/rootfs/etc/systemd/system/graphical.target.wants/m1892-stage3-acceptance.service" ] || fail acceptance-not-enabled
[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-stage3-acm-shell.service" ] || fail acm-not-enabled
grep -Fxq 'ConditionKernelCommandLine=m1892.usb=acm-ncm' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" || fail acm-usb-profile-condition
grep -Fxq 'ConditionPathExists=/dev/ttyGS0' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" || fail acm-device-condition
grep -Fq 'Requires=dev-ttyGS0.device' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" && fail acm-device-pulled
grep -Fxq 'After=dev-ttyGS0.device' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" || fail acm-device-order
grep -Fxq 'KillSignal=SIGHUP' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" || fail acm-stop-signal
grep -Fxq 'TimeoutStopSec=5s' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" || fail acm-stop-timeout
grep -Fq 'm1892-stage3-acceptance.service' \
	"$work/rootfs/etc/systemd/system/m1892-stage3-acm-shell.service" && fail acm-coupled-to-desktop
for target in sleep.target suspend.target hibernate.target \
	hybrid-sleep.target suspend-then-hibernate.target; do
	[ "$(readlink "$work/rootfs/etc/systemd/system/$target")" = /dev/null ] ||
		fail "recovery-suspend-not-masked:$target"
done
[ ! -e "$work/rootfs/etc/systemd/sleep.conf.d/50-m1892-s2idle.conf" ] ||
	fail recovery-sleep-config-present
[ ! -e "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-wake-policy.service" ] ||
	fail recovery-wake-policy-enabled
cmp -s "$work/rootfs/usr/libexec/m1892/wake-policy" \
	"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/wake-policy" ||
	fail wake-policy-content
sh "$work/rootfs/usr/libexec/m1892/wake-policy" --self-test >/dev/null ||
	fail wake-policy-self-test
cmp -s "$work/rootfs/etc/systemd/system/m1892-wake-policy.service" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/m1892-wake-policy.service" ||
	fail wake-policy-service-content
cmp -s "$work/rootfs/etc/udev/rules.d/92-m1892-wifi-wake.rules" \
	"$(dirname "$0")/../rootfs-overlay/etc/udev/rules.d/92-m1892-wifi-wake.rules" ||
	fail wifi-wake-udev-content
grep -Fqx 'ACTION=="bind", SUBSYSTEM=="platform", KERNEL=="18800000.wifi", DRIVER=="ath10k_snoc", ATTR{power/wakeup}="disabled"' \
	"$work/rootfs/etc/udev/rules.d/92-m1892-wifi-wake.rules" ||
	fail wifi-wake-udev-contract
[ "$(cat "$work/rootfs/etc/timezone")" = Asia/Shanghai ] || fail default-timezone
[ "$(readlink "$work/rootfs/etc/localtime")" = /usr/share/zoneinfo/Asia/Shanghai ] || fail localtime-link
module_root=$work/rootfs/lib/modules/$M1892_KERNEL_RELEASE
module_source=$(sed -n 's/^kernel_module_source=//p' "$metadata")
case "$module_source" in
	recovery-r545-subset)
		for module in qcom_pd_mapper.ko reset-qcom-pdc.ko qcom_q6v5_mss.ko \
			ath10k_snoc.ko ff-memless.ko dw7914-bounded-ff.ko; do
			[ -f "$module_root/extra/m1892/$module" ] ||
				fail "standard-module-absent:$module"
		done
		grep -Fq 'extra/m1892/qcom_q6v5_mss.ko:' "$module_root/modules.dep" ||
			fail mpss-modules-dep
		grep -Fq 'extra/m1892/ath10k_snoc.ko:' "$module_root/modules.dep" ||
			fail wlan-modules-dep
		;;
	public-clean-full)
		for module in kernel/fs/fuse/fuse.ko \
			kernel/drivers/gpu/drm/panel/panel-samsung-sofef00m.ko \
			kernel/drivers/media/platform/qcom/venus/venus-core.ko \
			kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko \
			kernel/drivers/remoteproc/qcom_q6v5_mss.ko; do
			[ -f "$module_root/$module" ] || fail "full-module-absent:$module"
		done
		[ -f "$module_root/modules.order" ] && [ -f "$module_root/modules.builtin" ] ||
			fail full-module-metadata-absent
		[ ! -e "$module_root/build" ] && [ ! -e "$module_root/source" ] ||
			fail full-module-host-symlink
		grep -Fxq 'fuse' "$work/rootfs/etc/modules-load.d/m1892-system.conf" ||
			fail fuse-not-configured
		grep -Fq 'kernel/fs/fuse/fuse.ko:' "$module_root/modules.dep" ||
			fail fuse-modules-dep
		grep -Fq 'kernel/drivers/remoteproc/qcom_q6v5_mss.ko:' \
			"$module_root/modules.dep" || fail mpss-modules-dep
		[ "$(sha256sum "$module_root/kernel/drivers/media/platform/qcom/venus/venus-core.ko" | awk '{print $1}')" = \
			761cbe91ac41cc25e3b05e27bb9e0dcb07eb8a3fc8c58de188f586213231ac20 ] ||
			fail venus-module-hash
		;;
	*) fail invalid-kernel-module-source ;;
esac
for firmware in ath10k/WCN3990/hw1.0/wlanmdsp.mbn \
	ath10k/WCN3990/hw1.0/board-2.bin ath10k/WCN3990/hw1.0/firmware-5.bin; do
	[ -e "$work/rootfs/lib/firmware/$firmware" ] || fail "owner-firmware-absent:$firmware"
done
[ "$(readlink "$work/rootfs/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn")" = \
	/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn ] || fail wlan-tqftp-link
owner_firmware_scope=$(sed -n 's/^owner_firmware_scope=//p' "$metadata")
case "$owner_firmware_scope" in
	source-recovery-subset)
		[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-mpss-firmware.service" ] || fail mss-firmware-unit-disabled
		[ -f "$work/rootfs/etc/systemd/system/m1892-radio-modules.service.d/10-runtime-mpss-extract.conf" ] || fail mss-radio-order-dropin-absent
		;;
	owner-local-complete)
		[ ! -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-mpss-firmware.service" ] || fail duplicate-mpss-provider
		owner_firmware=${M1892_STAGE3_OWNER_FIRMWARE_DIR:-}
		[ -f "$owner_firmware/FIRMWARE-MANIFEST.tsv" ] ||
			fail owner-firmware-verifier-input-absent
		expected_firmware_manifest=$(sed -n \
			's/^owner_firmware_manifest_sha256=//p' "$metadata")
		[ "$(sha256sum "$owner_firmware/FIRMWARE-MANIFEST.tsv" | awk '{print $1}')" = \
			"$expected_firmware_manifest" ] || fail owner-firmware-manifest-hash
		while IFS="$(printf '\t')" read -r expected_hash expected_size relative; do
			installed=$work/rootfs/$relative
			[ -f "$installed" ] && [ ! -L "$installed" ] ||
				fail "owner-firmware-file-absent:$relative"
			[ "$(stat -c %s "$installed")" = "$expected_size" ] &&
				[ "$(sha256sum "$installed" | awk '{print $1}')" = "$expected_hash" ] ||
				fail "owner-firmware-file-mismatch:$relative"
		done <"$owner_firmware/FIRMWARE-MANIFEST.tsv"
		for firmware in qcom/sdm845/Meizu/m1892/slpi.mdt \
			qcom/sdm845/m1892/adsp.mdt qcom/sdm845/m1892/ipa_fws.mdt \
			qcom/venus-5.2/venus.mbn; do
			[ -s "$work/rootfs/lib/firmware/$firmware" ] ||
				fail "complete-owner-firmware-absent:$firmware"
		done
		[ "$(sha256sum "$work/rootfs/usr/libexec/m1892/import-persist-sensors" | awk '{print $1}')" = \
			ac2c1b59b26ecc06d7d7537b7d597705cca1a84031c8b8a2ecf700be89b54ac7 ] ||
			fail persist-sensor-import-hash
		[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-persist-sensors.service" ] ||
			fail persist-sensor-import-disabled
		[ "$(sha256sum "$work/rootfs/etc/udev/rules.d/90-m1892-ssc-sensors.rules" | awk '{print $1}')" = \
			72ae72dab557f2b54acea6c26e2bc07ba2ae527374ee578c9b7f2fa32b24ea69 ] ||
			fail m1892-sensor-udev-hash
		grep -Fxq 'Environment=hexagonrpcd_fw_dir=/usr/share/qcom/sdm845/Meizu/m1892' \
			"$work/rootfs/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf" ||
			fail hexagonrpcd-firmware-root
		grep -Fq 'Requires=m1892-persist-sensors.service' \
			"$work/rootfs/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf" ||
			fail hexagonrpcd-persist-order
		[ "$(grep -c '^After=$' "$work/rootfs/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf")" = 1 ] ||
			fail hexagonrpcd-order-reset
		grep -Fxq 'After=m1892-persist-sensors.service' \
			"$work/rootfs/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf" ||
			fail hexagonrpcd-persist-after
		grep -Fxq 'Requires=hexagonrpcd.service' \
			"$work/rootfs/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" ||
			fail sensor-proxy-hexagon-requirement
		grep -Fxq 'After=hexagonrpcd.service' \
			"$work/rootfs/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" ||
			fail sensor-proxy-hexagon-order
		[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-bluetooth-transport.service" ] ||
			fail bluetooth-transport-disabled
		[ ! -e "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-bluetooth-identity.service" ] ||
			fail bluetooth-identity-boot-poll
		grep -Fxq 'ExecStart=/usr/sbin/modprobe hci_uart' \
			"$work/rootfs/etc/systemd/system/m1892-bluetooth-transport.service" ||
			fail bluetooth-transport-command
		grep -Fq 'ENV{SYSTEMD_WANTS}+="m1892-bluetooth-identity.service"' \
			"$work/rootfs/etc/udev/rules.d/91-m1892-bluetooth-identity.rules" ||
			fail bluetooth-identity-udev-trigger
		grep -Fxq 'BindsTo=sys-subsystem-bluetooth-devices-hci0.device' \
			"$work/rootfs/etc/systemd/system/m1892-bluetooth-identity.service" ||
			fail bluetooth-identity-device-binding
		grep -Fq 'qmicli -d qrtr://0 --dms-get-mac-address=bt' \
			"$work/rootfs/usr/libexec/m1892/bluetooth-identity" ||
			fail bluetooth-factory-address-source
		grep -Fq 'script -qec "btmgmt --index 0 public-addr $1"' \
			"$work/rootfs/usr/libexec/m1892/bluetooth-identity" ||
			fail bluetooth-address-command
		grep -Fq "script -qec 'btmgmt config' /dev/null" \
			"$work/rootfs/usr/libexec/m1892/bluetooth-identity" ||
			fail bluetooth-noninteractive-adapter
		grep -Fq 'config=$(bt_config || true)' \
			"$work/rootfs/usr/libexec/m1892/bluetooth-identity" ||
			fail bluetooth-index-wait-absent
		grep -Fq '[ "$i" -lt 150 ] || fail hci-index-timeout' \
			"$work/rootfs/usr/libexec/m1892/bluetooth-identity" ||
			fail bluetooth-index-wait-unbounded
		sh "$work/rootfs/usr/libexec/m1892/wifi-identity" --self-test >/dev/null ||
			fail wifi-identity-self-test
		grep -Fq 'qmicli -d qrtr://0 --dms-get-mac-address=wlan' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-factory-address-source
		grep -Fq 'policy=stable-ssid' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-stable-ssid-fallback
		grep -Fq 'policy=preserve' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-factory-address-preserve
		grep -Fq 'wifi.wake-on-wlan=0' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-wowlan-default
		grep -Fxq 'Wants=m1892-wifi-identity.service' \
			"$work/rootfs/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf" ||
			fail networkmanager-wifi-identity-want
		grep -Fxq 'After=m1892-wifi-identity.service' \
			"$work/rootfs/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf" ||
			fail networkmanager-wifi-identity-order
		grep -Fxq 'Before=NetworkManager.service' \
			"$work/rootfs/etc/systemd/system/m1892-wifi-identity.service" ||
			fail wifi-identity-before-networkmanager
		grep -Fq 'timeout 1 qmicli -d qrtr://0 --dms-get-mac-address=wlan' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-identity-qmi-probe-bound
		grep -Fq 'while [ ! -d /sys/class/net/wlan0 ] && [ "$wait_step" -lt 60 ]; do' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-identity-wlan-readiness-gate
		grep -Fq 'for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do' \
			"$work/rootfs/usr/libexec/m1892/wifi-identity" ||
			fail wifi-identity-qmi-retry-bound
		grep -Fxq 'TimeoutStartSec=25' \
			"$work/rootfs/etc/systemd/system/m1892-wifi-identity.service" ||
			fail wifi-identity-unbounded
		grep -Fxq 'ExecStartPre=/usr/libexec/m1892/wait-sensor-ready' \
			"$work/rootfs/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" ||
			fail sensor-proxy-readiness-probe
		grep -Fq 'ssccli --sensor accelerometer --timeout 2' \
			"$work/rootfs/usr/libexec/m1892/wait-sensor-ready" ||
			fail sensor-readiness-client-bound
		grep -Fq 'timeout -k 1 3 ssccli --sensor accelerometer --timeout 2' \
			"$work/rootfs/usr/libexec/m1892/wait-sensor-ready" ||
			fail sensor-readiness-process-bound
		grep -Fq 'Accelerometer sensor measurement:' \
			"$work/rootfs/usr/libexec/m1892/wait-sensor-ready" ||
			fail sensor-readiness-sample-gate
		grep -Fq 'while [ "$attempt" -lt 20 ]; do' \
			"$work/rootfs/usr/libexec/m1892/wait-sensor-ready" ||
			fail sensor-readiness-retry-bound
		grep -Fxq 'TimeoutStartSec=75' \
			"$work/rootfs/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" ||
			fail sensor-proxy-startup-bound
		grep -Fxq 'TimeoutStartSec=30' \
			"$work/rootfs/etc/systemd/system/m1892-bluetooth-identity.service" ||
			fail bluetooth-identity-unbounded
		[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-cellular-prepare.service" ] ||
			fail cellular-prepare-disabled
		grep -Fxq 'Requires=m1892-cellular-prepare.service' \
			"$work/rootfs/etc/systemd/system/ModemManager.service.d/10-m1892-cellular.conf" ||
			fail modemmanager-cellular-order
		for contract in \
			"e388c6676d7c62076b37e5a526468a8204aa2449fa05e231a5d328d340baa21f usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf" \
			"a07e5a5e3c6140793dae9ae10f31906aa531847dabab8c18788b99ec33a2a69e usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf" \
			"85f48b33f1ec1865b1e66c3b10f64fc1a2c8e44f1515bb13a831836832a962d9 usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf"; do
			set -- $contract
			[ "$(sha256sum "$work/rootfs/$2" | awk '{print $1}')" = "$1" ] ||
				fail "ucm-hash:$2"
		done
		[ -x "$work/rootfs/usr/libexec/m1892/venus-selftest" ] ||
				fail venus-selftest-absent
		grep -Fq 'v4l2h264enc ! v4l2h264dec ! fakesink' \
			"$work/rootfs/usr/libexec/m1892/venus-selftest" ||
			fail venus-gstreamer-roundtrip-gate
		grep -Fq 'runtime_active_time' "$work/rootfs/usr/libexec/m1892/venus-selftest" ||
			fail venus-runtime-pm-gate
		;;
	*) fail invalid-owner-firmware-scope ;;
esac
q6voiced_scope=$(sed -n 's/^q6voiced_scope=//p' "$metadata")
[ -n "$q6voiced_scope" ] || q6voiced_scope=absent
phone_image=no
if awk 'BEGIN { RS="" } $0 ~ /(^|\n)Package: plasma-mobile-phone\n/ &&
		$0 ~ /\nStatus: install ok installed(\n|$)/ { found=1 } END { exit(found ? 0 : 1) }' \
		"$work/rootfs/var/lib/dpkg/status"; then
	phone_image=yes
fi
case "$q6voiced_scope" in
	absent)
		[ "$phone_image" = no ] || fail phone-image-without-m1892-q6voiced
		;;
	m1892-debian-native)
		[ "$phone_image" = yes ] || fail q6voiced-without-phone-stack
		q6voiced=$work/rootfs/usr/libexec/m1892/q6voiced
		[ -x "$q6voiced" ] || fail q6voiced-binary-absent
		[ "$(sha256sum "$q6voiced" | awk '{print $1}')" = \
			"$(sed -n 's/^q6voiced_sha256=//p' "$metadata")" ] || fail q6voiced-binary-hash
		q6voiced_input=${M1892_STAGE3_Q6VOICED_DIR:-}
		[ -f "$q6voiced_input/BUILD-METADATA.txt" ] ||
			fail q6voiced-verifier-input-absent
		grep -Fxq 'source_sha256=2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4' \
			"$q6voiced_input/BUILD-METADATA.txt" || fail q6voiced-source-contract
		[ "$(sha256sum "$q6voiced_input/q6voiced" | awk '{print $1}')" = \
			"$(sha256sum "$q6voiced" | awk '{print $1}')" ] || fail q6voiced-verifier-binary
		[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-q6voiced.service" ] ||
			fail q6voiced-service-disabled
		unit=$work/rootfs/etc/systemd/system/m1892-q6voiced.service
		grep -Fxq 'ExecStart=/usr/libexec/m1892/q6voiced hw:0,0' "$unit" ||
			fail q6voiced-pcm-contract
		grep -Fxq 'After=dbus.service sound.target m1892-radio-online.service ModemManager.service' "$unit" ||
			fail q6voiced-order
		grep -Fxq 'User=daemon' "$unit" && grep -Fxq 'Group=audio' "$unit" ||
			fail q6voiced-privilege
		grep -Fxq 'ProtectSystem=strict' "$unit" || fail q6voiced-sandbox
		;;
	*) fail invalid-q6voiced-scope ;;
esac
callaudiod_scope=$(sed -n 's/^callaudiod_scope=//p' "$metadata")
[ -n "$callaudiod_scope" ] || callaudiod_scope=absent
case "$callaudiod_scope" in
	absent|distribution)
		[ "$phone_image" = no ] || fail phone-image-without-patched-callaudiod
		;;
	m1892-split-profile)
		[ "$phone_image" = yes ] || fail patched-callaudiod-without-phone-stack
		callaudiod=$work/rootfs/usr/libexec/m1892/callaudiod
		[ -x "$callaudiod" ] || fail patched-callaudiod-binary-absent
		[ "$(sha256sum "$callaudiod" | awk '{print $1}')" = \
			"$(sed -n 's/^callaudiod_sha256=//p' "$metadata")" ] ||
			fail patched-callaudiod-binary-hash
		callaudiod_input=${M1892_STAGE3_CALLAUDIOD_DIR:-}
		[ -f "$callaudiod_input/BUILD-METADATA.txt" ] ||
			fail patched-callaudiod-verifier-input-absent
		grep -Fxq 'm1892_patch_sha256=ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e' \
			"$callaudiod_input/BUILD-METADATA.txt" || fail patched-callaudiod-source-contract
		service=$work/rootfs/usr/share/dbus-1/services/org.mobian_project.CallAudio.service
		grep -Fxq 'Name=org.mobian_project.CallAudio' "$service" &&
			grep -Fxq 'Exec=/usr/libexec/m1892/callaudiod' "$service" ||
			fail patched-callaudiod-dbus-activation
		;;
	*) fail invalid-callaudiod-scope ;;
esac
spacebar_scope=$(sed -n 's/^spacebar_scope=//p' "$metadata")
[ -n "$spacebar_scope" ] || spacebar_scope=distribution
case "$spacebar_scope" in
	distribution)
		[ "$phone_image" = no ] || fail phone-image-without-patched-spacebar
		;;
	m1892-multi-bearer)
		[ "$phone_image" = yes ] || fail patched-spacebar-without-phone-stack
		spacebar=$work/rootfs/usr/lib/aarch64-linux-gnu/libexec/spacebar-daemon
		[ -x "$spacebar" ] || fail patched-spacebar-binary-absent
		[ "$(sha256sum "$spacebar" | awk '{print $1}')" = \
			"$(sed -n 's/^spacebar_sha256=//p' "$metadata")" ] ||
			fail patched-spacebar-binary-hash
		spacebar_input=${M1892_STAGE5_SPACEBAR_DIR:-}
		[ -f "$spacebar_input/BUILD-METADATA.txt" ] ||
			fail patched-spacebar-verifier-input-absent
		grep -Fxq 'component=m1892-debian13-spacebar-multi-bearer' \
			"$spacebar_input/BUILD-METADATA.txt" || fail patched-spacebar-source-contract
		grep -aFq 'Ignoring IMS bearer for Spacebar data state:' "$spacebar" ||
			fail patched-spacebar-ims-filter
		! grep -aFq 'deleteBearer' "$spacebar" || fail patched-spacebar-destructive-api
		;;
	*) fail invalid-spacebar-scope ;;
esac
ims_scope=$(sed -n 's/^ims_scope=//p' "$metadata")
[ -n "$ims_scope" ] || ims_scope=absent
case "$ims_scope" in
	absent)
		[ "$phone_image" = no ] || fail phone-image-without-ims-runtime
		;;
		clean-native)
		[ "$phone_image" = yes ] || fail ims-runtime-without-phone-stack
		ims_input=${M1892_STAGE5_IMS_DIR:-}
		[ -f "$ims_input/BUILD-METADATA.txt" ] && [ -f "$ims_input/SHA256SUMS" ] ||
			fail ims-runtime-verifier-input-absent
			[ "$(sha256sum "$ims_input/SHA256SUMS" | awk '{print $1}')" = \
				"$(sed -n 's/^ims_runtime_manifest_sha256=//p' "$metadata")" ] ||
				fail ims-runtime-manifest-hash
			for contract in \
				'voltd_no_main_default_patch_sha256=17b9a34eb2e4cc804c9ae1d45959eb372c85a3b9f48a7fa00223c5136922a4a5' \
				'voltd_main_default_install=absent' \
				'voltd_stale_main_default_cleanup=present' \
				'voltd_ra_default_router_acceptance=disabled' \
				'voltd_link_address_dad=preserved'; do
				grep -Fxq "$contract" "$ims_input/BUILD-METADATA.txt" ||
					fail "ims-input-route-contract:$contract"
			done
			grep -Fxq 'ims_voltd_no_main_default_patch_sha256=17b9a34eb2e4cc804c9ae1d45959eb372c85a3b9f48a7fa00223c5136922a4a5' \
				"$metadata" || fail ims-image-route-patch
			for contract in \
				'ims_voltd_main_default_install=absent' \
				'ims_voltd_stale_main_default_cleanup=present' \
				'ims_voltd_ra_default_router_acceptance=disabled' \
				'ims_voltd_link_address_dad=preserved'; do
				grep -Fxq "$contract" "$metadata" || fail "ims-image-route-contract:$contract"
			done
		for path in \
			opt/m1892-openimsd/lib/girepository-1.0/Qmi-1.0.typelib \
			opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/libqmi-glib.so.5.12.0 \
			opt/m1892-modemmanager/sbin/ModemManager \
			usr/libexec/m1892/m1892-81voltd; do
			[ -f "$work/rootfs/$path" ] || fail "ims-runtime-path:$path"
			[ "$(sha256sum "$work/rootfs/$path" | awk '{print $1}')" = \
				"$(sha256sum "$ims_input/$path" | awk '{print $1}')" ] ||
				fail "ims-runtime-file-hash:$path"
		done
			modemmanager=$work/rootfs/opt/m1892-modemmanager/sbin/ModemManager
			voltd=$work/rootfs/usr/libexec/m1892/m1892-81voltd
			strings "$voltd" | grep -Fxq '/proc/sys/net/ipv6/conf/%s/accept_ra_defrtr' ||
				fail ims-voltd-ra-policy
			strings "$voltd" | grep -Fxq 'Removed stale IMS main-table defaults from %s' ||
				fail ims-voltd-route-cleanup
		aarch64-linux-gnu-readelf -d "$modemmanager" |
			grep -Fq '/opt/m1892-modemmanager/lib/aarch64-linux-gnu:/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu' ||
			fail ims-modemmanager-runpath
		! aarch64-linux-gnu-readelf -d "$modemmanager" | grep -Eq -- '-final|-972' ||
			fail ims-modemmanager-development-runpath
		grep -aFq 'qmi_message_wms_raw_send_input_set_sms_on_ims' "$modemmanager" ||
			fail ims-modemmanager-sms-on-ims
		grep -Fq 'Skipping destructive IMS reset; preserving active packet data' \
			"$work/rootfs/opt/m1892-openimsd/qcom-imsd/src/qcom_imsd/main.py" ||
			fail ims-qcom-idempotent-reset
		grep -Fq 'Required IMS services are already enabled' \
			"$work/rootfs/opt/m1892-openimsd/qcom-imsd/src/qcom_imsd/main.py" ||
			fail ims-qcom-idempotent-config
		grep -Fxq 'ExecStart=/opt/m1892-modemmanager/sbin/ModemManager' \
			"$work/rootfs/etc/systemd/system/ModemManager.service.d/20-m1892-ims-runtime.conf" ||
			fail ims-modemmanager-service
		[ -x "$work/rootfs/etc/NetworkManager/dispatcher.d/90-m1892-ims-online" ] ||
			fail ims-dispatcher-absent
		[ ! -e "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-81voltd.service" ] &&
			[ ! -e "$work/rootfs/etc/systemd/system/multi-user.target.wants/m1892-qcom-imsd.service" ] ||
			fail ims-services-bypass-cellular-gate
		;;
	*) fail invalid-ims-scope ;;
esac
grep -Fxq 'blacklist ath10k_snoc' \
	"$work/rootfs/etc/modprobe.d/m1892-radio-order.conf" || fail wlan-blacklist
grep -Fxq 'softdep qcom_q6v5_mss pre: qcom_pd_mapper reset_qcom_pdc' \
	"$work/rootfs/etc/modprobe.d/m1892-radio-order.conf" || fail mpss-softdep
for unit in m1892-radio-modules.service m1892-radio-online.service; do
	[ -f "$work/rootfs/etc/systemd/system/$unit" ] || fail "radio-unit-absent:$unit"
	[ -L "$work/rootfs/etc/systemd/system/multi-user.target.wants/$unit" ] || fail "radio-unit-disabled:$unit"
done
[ "$(sha256sum "$work/rootfs/usr/libexec/m1892/m1892-fat16-mss-extract" | awk '{print $1}')" = \
	"$mss_extractor_sha" ] || fail mss-extractor-hash
grep -Fq 'Requires=dev-disk-by\x2dpartlabel-modembak.device' \
	"$work/rootfs/etc/systemd/system/m1892-mpss-firmware.service" || fail mss-device-order
grep -Fq '/dev/disk/by-partlabel/modembak' \
	"$work/rootfs/etc/systemd/system/m1892-mpss-firmware.service" || fail mss-source-partition
grep -Fxq 'ProtectSystem=strict' \
	"$work/rootfs/etc/systemd/system/m1892-mpss-firmware.service" || fail mss-service-sandbox
for binary in /usr/bin/rmtfs /usr/bin/tqftpserv /usr/bin/qrtr-ns; do
	[ -x "$work/rootfs$binary" ] || fail "radio-binary-absent:$binary"
done
[ ! -e "$work/rootfs/usr/bin/pd-mapper" ] || fail duplicate-userspace-pd-mapper
grep -Fxq 'ExecStart=/usr/bin/rmtfs -r -P -s' \
	"$work/rootfs/usr/lib/systemd/system/rmtfs.service" || fail rmtfs-read-only-policy
[ -f "$work/rootfs/usr/lib/systemd/system/rmtfs.service" ] || fail rmtfs-unit-absent
[ -f "$work/rootfs/usr/lib/systemd/system/tqftpserv.service" ] || fail tqftp-unit-absent
[ -f "$work/rootfs/usr/lib/systemd/system/qrtr-ns.service" ] || fail qrtr-unit-absent
grep -Fq 'ExecStart=/usr/bin/rmtfs -r -P -s' \
	"$work/rootfs/usr/lib/systemd/system/rmtfs.service" || fail rmtfs-not-read-only
private_network=$(sed -n 's/^private_network_injected=//p' "$metadata")
private_network_type=$(sed -n 's/^private_network_type=//p' "$metadata")
case "$private_network" in
	no)
		[ "$private_network_type" = none ] || fail private-network-type-without-profile
		find "$work/rootfs/etc/NetworkManager/system-connections" -mindepth 1 \
			-print -quit 2>/dev/null | grep -q . && fail private-network-profile
		;;
	yes)
		case "$private_network_type" in wifi|gsm) ;; *) fail invalid-private-network-type ;; esac
		local_profile=${M1892_STAGE3_NM_PROFILE:-}
		[ -f "$local_profile" ] || fail local-network-verifier-input-absent
		expected_profile_sha=$(sed -n 's/^private_network_profile_sha256=//p' "$metadata")
		[ "$(sha256sum "$local_profile" | awk '{print $1}')" = "$expected_profile_sha" ] ||
			fail local-network-source-hash
		installed_profile=$work/rootfs/etc/NetworkManager/system-connections/m1892-local-test.nmconnection
		[ -f "$installed_profile" ] || fail local-network-profile-absent
		[ "$(sha256sum "$installed_profile" | awk '{print $1}')" = "$expected_profile_sha" ] ||
			fail local-network-installed-hash
		if grep -Eq '^key-mgmt=(wpa-psk|sae)$' "$installed_profile"; then
			grep -Eq '^psk=.+$' "$installed_profile" || fail local-network-secret-absent
		fi
		grep -Fxq "type=$private_network_type" "$installed_profile" ||
			fail local-network-profile-type
		[ "$(stat -c %a "$installed_profile")" = 600 ] || fail local-network-profile-mode
		[ "$(find "$work/rootfs/etc/NetworkManager/system-connections" -mindepth 1 \
			-maxdepth 1 -type f | wc -l)" = 1 ] || fail local-network-profile-count
		;;
	*) fail invalid-private-network-metadata ;;
esac
find "$work/rootfs/root" "$work/rootfs/home" -path '*/.ssh/*' -print -quit 2>/dev/null | grep -q . && fail owner-ssh-data

{
	printf 'result=pass\n'
	printf 'recovery_sha256=%s\n' "$(sha256sum "$recovery" | awk '{print $1}')"
	printf 'rootfs_sha256=%s\n' "$rootfs_sha"
	printf 'root_image_size=%s\n' "$image_bytes"
	printf 'stock_tail_changed=no\n'
	printf 'persistent_boot_modified=no\nuserdata_modified=no\n'
	printf 'root_mode=ram-loopback\n'
	printf 'plasma_mobile_autologin=recovery-live-only\n'
	printf 'development_usb=acm-ncm\n'
	printf 'automatic_suspend=masked-recovery-only\n'
	printf 'suspend_policy=masked\n'
	printf 'private_network_injected=%s\n' "$private_network"
	printf 'private_network_type=%s\n' "$private_network_type"
	printf 'kernel_mode=%s\n' "$kernel_mode"
	printf 'kernel_module_source=%s\n' "$module_source"
	printf 'provider_mode=%s\n' "$provider_mode"
	printf 'kernel_release=%s\n' "$M1892_KERNEL_RELEASE"
	printf 'owner_firmware_scope=%s\n' "$owner_firmware_scope"
	printf 'q6voiced_scope=%s\n' "$q6voiced_scope"
	printf 'callaudiod_scope=%s\n' "$callaudiod_scope"
	printf 'spacebar_scope=%s\n' "$spacebar_scope"
	printf 'ims_scope=%s\n' "$ims_scope"
	printf 'radio_runtime=debian-systemd\n'
} >"$evidence_dir/verification.env"
cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_STAGE3_ARTIFACT_VERIFY_PASS
