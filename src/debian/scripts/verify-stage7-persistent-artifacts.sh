#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_recovery=${1:-}
recovery=${2:-}
rootfs=${3:-}
evidence_dir=${4:-}
[ -f "$source_recovery" ] && [ -f "$recovery" ] && [ -f "$rootfs" ] &&
	[ -n "$evidence_dir" ] || {
	echo "usage: $0 SOURCE_RECOVERY PERSISTENT_RECOVERY ROOTFS_GZ EVIDENCE_DIR" >&2
	exit 2
}
fail() { echo "M1892_DEBIAN_STAGE7_VERIFY_FAIL: $*" >&2; exit 1; }
expected_development_console=${M1892_EXPECT_DEVELOPMENT_CONSOLE:-}
spacebar_input=${M1892_STAGE5_SPACEBAR_DIR:-}
ims_input=${M1892_STAGE5_IMS_DIR:-}
case "$expected_development_console" in
	acm-root-shell|disabled) ;;
	*) fail expected-development-console-not-declared ;;
esac
[ -f "$spacebar_input/BUILD-METADATA.txt" ] &&
	[ -f "$spacebar_input/spacebar-daemon" ] &&
	[ -f "$ims_input/BUILD-METADATA.txt" ] &&
	[ -f "$ims_input/SHA256SUMS" ] || fail stage5-runtime-input-absent
for command in aarch64-linux-gnu-readelf blkid cmp cpio debugfs e2fsck find gzip \
	md5sum python3 sha256sum stat strings; do
	command -v "$command" >/dev/null || fail "missing-command:$command"
done
[ "$(stat -c %s "$source_recovery")" = 67108864 ] || fail source-size
[ "$(stat -c %s "$recovery")" = 67108864 ] || fail recovery-size
[ -f "$rootfs.sha256" ] || fail rootfs-sidecar
(cd "$(dirname "$rootfs")" && sha256sum -c "$(basename "$rootfs").sha256") >/dev/null ||
	fail rootfs-hash
rootfs_sha=$(awk 'NR == 1 { print $1 }' "$rootfs.sha256")
metadata=$(dirname "$rootfs")/BUILD-METADATA.txt
recovery_metadata=$(dirname "$recovery")/BUILD-METADATA.txt
[ -f "$metadata" ] && [ -f "$recovery_metadata" ] || fail metadata-absent
grep -Fxq 'root_mode=persistent-userdata-image' "$metadata" || fail rootfs-mode
account_mode=$(sed -n 's/^account_mode=//p' "$metadata")
case "$account_mode" in development-persistent|oem-owner) ;; *) fail account-mode ;; esac
suspend_policy=$(sed -n 's/^suspend_policy=//p' "$metadata")
case "$suspend_policy" in masked|manual) ;; *) fail suspend-policy ;; esac
development_console=$(sed -n 's/^development_console=//p' "$metadata")
[ "$development_console" = "$expected_development_console" ] ||
	fail unexpected-development-console
daily_packages=$(sed -n 's/^daily_packages=//p' "$metadata")
case "$daily_packages" in
	''|none) ;;
	*)
		expected_daily=angelfish,qmlkonsole,dolphin,plasma-systemmonitor,kdeconnect,flatpak,systemd-timesyncd,fastfetch,kde-spectacle,docker.io,docker-cli,docker-compose,docker-buildx,retroarch,libretro-core-info,libretro-gambatte,libretro-mgba,libretro-nestopia
		case "$account_mode:$development_console" in
			development-persistent:acm-root-shell)
			expected_config=stage6-image.env
			expected_suspend_policy=masked
			;;
			oem-owner:acm-root-shell)
				expected_daily=$expected_daily,calamares,pkexec,sudo
				expected_config=stage6-oem-development-image.env
				expected_suspend_policy=masked
				;;
			oem-owner:disabled)
				expected_daily=$expected_daily,calamares,pkexec,sudo
				expected_config=stage6-oem-image.env
				expected_suspend_policy=masked
				;;
			*) fail daily-config-mode-contract ;;
		esac
		[ "$daily_packages" = "$expected_daily" ] || fail daily-package-contract
		[ "$suspend_policy" = "$expected_suspend_policy" ] ||
			fail daily-suspend-policy-contract
		parent_config_sha=$(sed -n 's/^rootfs_config_sha256=//p' "$metadata")
		[ "$parent_config_sha" = \
			"$(sha256sum "$(dirname "$0")/../config/$expected_config" | awk '{print $1}')" ] ||
			fail daily-parent-config-hash
		;;
esac
grep -Fxq 'filesystem_uuid=de131892-0000-4000-8000-000000000007' "$metadata" ||
	fail rootfs-uuid-metadata
grep -Fxq 'root_mode=persistent-userdata' "$recovery_metadata" || fail recovery-mode
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' "$recovery_metadata" ||
	fail recovery-uuid
grep -Fxq 'persistent_label=M1892_DEB13' "$recovery_metadata" || fail recovery-label
[ "$(sed -n 's/^rootfs_sha256=//p' "$recovery_metadata")" = "$rootfs_sha" ] ||
	fail recovery-rootfs-binding

work=$(mktemp -d /tmp/m1892-debian-stage7-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/initramfs" "$work/root" "$evidence_dir"
dd if="$source_recovery" of="$work/source-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
dd if="$recovery" of="$work/output-tail" bs=1M iflag=skip_bytes \
	skip=26091520 status=none
cmp -s "$work/source-tail" "$work/output-tail" || fail stock-tail-changed
python3 - "$recovery" "$work/initramfs.gz" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if raw[:8] != b'ANDROID!': raise SystemExit('outer-magic')
oks, ors, ops = (struct.unpack_from('<I', raw, off)[0] for off in (8, 16, 36))
oro = ops + ((oks + ops - 1) // ops) * ops
inner = raw[oro:oro + ors]
if inner[:8] != b'ANDROID!': raise SystemExit('inner-magic')
iks, irs, ips = (struct.unpack_from('<I', inner, off)[0] for off in (8, 16, 36))
iro = ips + ((iks + ips - 1) // ips) * ips
open(sys.argv[2], 'wb').write(inner[iro:iro + irs])
PY
gzip -dc "$work/initramfs.gz" >"$work/initramfs.cpio"
(cd "$work/initramfs" && cpio -idm --quiet <"$work/initramfs.cpio")
init=$work/initramfs/init
[ -x "$init" ] || fail init-absent
grep -Fxq 'root_mode=persistent-userdata' "$init" || fail init-root-mode
grep -Fxq 'persistent_uuid=de131892-0000-4000-8000-000000000007' "$init" ||
	fail init-uuid
grep -Fxq 'persistent_label=M1892_DEB13' "$init" || fail init-label
grep -Fq 'prepare_persistent_root()' "$init" || fail init-persistent-function
grep -Fq 'normalize_core_device_permissions()' "$init" || fail init-device-mode-function
grep -Fq 'for device in null zero full random urandom tty' "$init" ||
	fail init-device-mode-list
grep -Fq 'chmod 0666 "/dev/$device"' "$init" || fail init-device-mode-command
grep -Fq 'mount -t ext4 -o ro,noload,noatime /dev/sda19' "$init" ||
	fail init-read-only-first-mount
grep -Fq 'umount "$newroot" || return 1' "$init" || fail init-validation-unmount
grep -Fq 'mount -t ext4 -o rw,noatime /dev/sda19 "$newroot"' "$init" ||
	fail init-journaled-rw-mount
grep -Fq 'remount,rw' "$init" && fail init-noload-remount
grep -Fq 'PARTNAME=userdata' "$init" || fail init-partlabel-guard
grep -Fq 'rootfs_id=m1892-debian13-stage7-persistent' "$init" || fail init-identity
grep -Eq 'mkfs|resize2fs|e2fsck' "$init" && fail init-destructive-command
if grep -Eo '/dev/sda[0-9]+' "$init" | grep -Fvx /dev/sda19 | grep -q .; then
	fail init-wrong-partition-reference
fi

gzip -dc "$rootfs" >"$work/rootfs.ext4"
image_bytes=$(sed -n 's/^persistent_root_image_size=//p' "$metadata")
image_sha=$(sed -n 's/^persistent_root_image_sha256=//p' "$metadata")
[ "$(stat -c %s "$work/rootfs.ext4")" = "$image_bytes" ] || fail image-size
[ "$(sha256sum "$work/rootfs.ext4" | awk '{print $1}')" = "$image_sha" ] || fail image-hash
e2fsck -fn "$work/rootfs.ext4" >"$evidence_dir/e2fsck.log" 2>&1 || fail e2fsck
[ "$(blkid -s TYPE -o value "$work/rootfs.ext4")" = ext4 ] || fail image-type
[ "$(blkid -s LABEL -o value "$work/rootfs.ext4")" = M1892_DEB13 ] || fail image-label
[ "$(blkid -s UUID -o value "$work/rootfs.ext4")" = de131892-0000-4000-8000-000000000007 ] ||
	fail image-uuid
for path in /etc/m1892-rootfs-identity /etc/passwd /etc/group /etc/shadow /var/lib/dpkg/status \
	/etc/systemd/system/m1892-persistent-first-boot.service \
	/etc/systemd/system/m1892-stage3-acm-shell.service \
	/etc/systemd/system/m1892-wifi-identity.service \
	/etc/systemd/system/m1892-wake-policy.service \
	/etc/udev/rules.d/92-m1892-wifi-wake.rules \
	/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf \
	/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf \
	/etc/systemd/system/sddm.service.d/10-m1892-iio-sensor-proxy.conf \
	/etc/xdg/plasmamobilerc /etc/xdg/powerdevilrc \
	/etc/skel/.config/kglobalshortcutsrc \
	/etc/skel/.config/kwinrulesrc \
	/usr/libexec/m1892/persistent-first-boot /usr/libexec/m1892/wifi-identity \
	/usr/libexec/m1892/wake-policy /usr/libexec/m1892/wait-sensor-ready \
	/usr/libexec/m1892/q6voiced \
	/usr/libexec/m1892/callaudiod /usr/libexec/m1892/cellular-acceptance \
	/usr/libexec/m1892/stage3-acceptance \
	/usr/libexec/m1892/stage3-session-acceptance \
	/usr/share/dbus-1/services/org.mobian_project.CallAudio.service; do
	name=$(printf '%s' "$path" | tr '/' '_')
	debugfs -R "dump $path $work/root/$name" "$work/rootfs.ext4" >/dev/null 2>&1 ||
		fail "image-file:$path"
done
identity=$work/root/_etc_m1892-rootfs-identity
grep -Fxq 'rootfs_id=m1892-debian13-stage7-persistent' "$identity" || fail identity-file
grep -Fxq 'root_mode=persistent-userdata' "$identity" || fail identity-mode
grep -Fxq "suspend_policy=$suspend_policy" "$identity" || fail identity-suspend-policy
grep -Fxq 'disabledQuickSettings=org.kde.plasma.quicksetting.record' \
	"$work/root/_etc_xdg_plasmamobilerc" || fail quick-settings-policy
cmp -s "$work/root/_etc_xdg_powerdevilrc" \
	"$(dirname "$0")/../rootfs-overlay/etc/xdg/powerdevilrc" ||
	fail powerdevil-manual-policy-content
[ "$(grep -Fxc 'AutoSuspendAction=0' "$work/root/_etc_xdg_powerdevilrc")" = 3 ] ||
	fail powerdevil-manual-policy-count
grep -Fxq 'PowerOff=Power Off,none,Power Off' \
	"$work/root/_etc_skel_.config_kglobalshortcutsrc" || fail power-key-toggle-shortcut
grep -Fxq 'Turn Off Screen=none,Power Off,Turn Off Screen' \
	"$work/root/_etc_skel_.config_kglobalshortcutsrc" || fail power-key-one-way-shortcut-disabled
cmp -s "$work/root/_etc_skel_.config_kwinrulesrc" \
	"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/kwinrulesrc" ||
	fail gamescope-fullscreen-rule-content
grep -Fxq 'wmclass=gamescope' "$work/root/_etc_skel_.config_kwinrulesrc" ||
	fail gamescope-fullscreen-window-class
grep -Fxq 'fullscreenrule=3' "$work/root/_etc_skel_.config_kwinrulesrc" ||
	fail gamescope-fullscreen-force-rule
grep -Fxq 'rules=1' "$work/root/_etc_skel_.config_kwinrulesrc" ||
	fail gamescope-fullscreen-rule-list
grep -Fxq "account_mode=$account_mode" "$identity" || fail identity-account-mode
cmp -s "$work/root/_etc_systemd_system_sddm.service.d_10-m1892-iio-sensor-proxy.conf" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/sddm.service.d/10-m1892-iio-sensor-proxy.conf" || \
	fail sddm-iio-startup-order-content
grep -Fxq 'Wants=iio-sensor-proxy.service' \
	"$work/root/_etc_systemd_system_sddm.service.d_10-m1892-iio-sensor-proxy.conf" || \
	fail sddm-iio-startup-order-wants
grep -Fxq 'After=iio-sensor-proxy.service' \
	"$work/root/_etc_systemd_system_sddm.service.d_10-m1892-iio-sensor-proxy.conf" || \
	fail sddm-iio-startup-order-after
debugfs -R 'stat /usr/libexec/m1892/cellular-acceptance' "$work/rootfs.ext4" \
	>"$work/cellular-acceptance-stat" 2>&1 || fail cellular-acceptance-stat
grep -Eq 'Mode:[[:space:]]+0755' "$work/cellular-acceptance-stat" &&
	grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
		"$work/cellular-acceptance-stat" || fail cellular-acceptance-mode
cmp -s "$work/root/_usr_libexec_m1892_cellular-acceptance" \
	"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/cellular-acceptance" ||
	fail cellular-acceptance-content
sh "$work/root/_usr_libexec_m1892_cellular-acceptance" --self-test >/dev/null ||
	fail cellular-acceptance-self-test
cmp -s "$work/root/_usr_libexec_m1892_wifi-identity" \
	"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/wifi-identity" ||
	fail wifi-identity-content
sh "$work/root/_usr_libexec_m1892_wifi-identity" --self-test >/dev/null ||
	fail wifi-identity-self-test
grep -Fq 'wifi.wake-on-wlan=0' "$work/root/_usr_libexec_m1892_wifi-identity" ||
	fail wifi-wowlan-default
cmp -s "$work/root/_etc_systemd_system_m1892-wifi-identity.service" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/m1892-wifi-identity.service" ||
	fail wifi-identity-service-content
cmp -s "$work/root/_etc_systemd_system_NetworkManager.service.d_15-m1892-wifi-identity.conf" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf" ||
	fail networkmanager-wifi-identity-dropin-content
cmp -s "$work/root/_usr_libexec_m1892_wake-policy" \
	"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/wake-policy" ||
	fail wake-policy-content
sh "$work/root/_usr_libexec_m1892_wake-policy" --self-test >/dev/null ||
	fail wake-policy-self-test
cmp -s "$work/root/_etc_systemd_system_m1892-wake-policy.service" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/m1892-wake-policy.service" ||
	fail wake-policy-service-content
cmp -s "$work/root/_etc_udev_rules.d_92-m1892-wifi-wake.rules" \
	"$(dirname "$0")/../rootfs-overlay/etc/udev/rules.d/92-m1892-wifi-wake.rules" ||
	fail wifi-wake-udev-content
grep -Fqx 'ACTION=="bind", SUBSYSTEM=="platform", KERNEL=="18800000.wifi", DRIVER=="ath10k_snoc", ATTR{power/wakeup}="disabled"' \
	"$work/root/_etc_udev_rules.d_92-m1892-wifi-wake.rules" ||
	fail wifi-wake-udev-contract
target_is_masked()
{
	debugfs -R "stat /etc/systemd/system/$1" "$work/rootfs.ext4" 2>/dev/null |
		grep -Fq 'Fast link dest: "/dev/null"'
}
case "$suspend_policy" in
	masked)
		for target in sleep.target suspend.target hibernate.target \
			hybrid-sleep.target suspend-then-hibernate.target; do
			target_is_masked "$target" || fail "suspend-target-not-masked:$target"
		done
		debugfs -R 'stat /etc/systemd/sleep.conf.d/50-m1892-s2idle.conf' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' &&
			fail masked-sleep-config-present
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-wake-policy.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' &&
			fail masked-wake-policy-enabled
		grep -Fxq 'automatic_suspend=masked-development' "$metadata" ||
			fail masked-automatic-suspend-metadata
		;;
	manual)
		for target in sleep.target suspend.target; do
			target_is_masked "$target" && fail "manual-target-masked:$target"
		done
		for target in hibernate.target hybrid-sleep.target \
			suspend-then-hibernate.target; do
			target_is_masked "$target" || fail "hibernate-target-not-masked:$target"
		done
		debugfs -R 'dump /etc/systemd/sleep.conf.d/50-m1892-s2idle.conf /dev/stdout' \
			"$work/rootfs.ext4" >"$work/root/_etc_systemd_sleep.conf.d_50-m1892-s2idle.conf" \
			2>/dev/null || fail manual-sleep-config
		cmp -s "$work/root/_etc_systemd_sleep.conf.d_50-m1892-s2idle.conf" \
			"$(dirname "$0")/../rootfs-overlay/etc/systemd/sleep.conf.d/50-m1892-s2idle.conf" ||
			fail manual-sleep-config-content
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-wake-policy.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q 'Type: symlink' ||
			fail manual-wake-policy-disabled
		grep -Fxq 'automatic_suspend=disabled-manual-only' "$metadata" ||
			fail manual-automatic-suspend-metadata
		;;
esac
cmp -s "$work/root/_usr_libexec_m1892_wait-sensor-ready" \
	"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/wait-sensor-ready" ||
	fail sensor-readiness-content
cmp -s "$work/root/_etc_systemd_system_iio-sensor-proxy.service.d_10-m1892-ssc.conf" \
	"$(dirname "$0")/../rootfs-overlay/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" ||
	fail sensor-proxy-dropin-content
grep -Fq 'timeout -k 1 3 ssccli --sensor accelerometer --timeout 2' \
	"$work/root/_usr_libexec_m1892_wait-sensor-ready" ||
	fail sensor-readiness-process-bound
grep -Fq 'while [ "$attempt" -lt 20 ]; do' \
	"$work/root/_usr_libexec_m1892_wait-sensor-ready" ||
	fail sensor-readiness-retry-bound
grep -Fxq 'TimeoutStartSec=75' \
	"$work/root/_etc_systemd_system_iio-sensor-proxy.service.d_10-m1892-ssc.conf" ||
	fail sensor-proxy-startup-bound
for helper in stage3-acceptance stage3-session-acceptance; do
	name=$(printf '%s' "/usr/libexec/m1892/$helper" | tr '/' '_')
	cmp -s "$work/root/$name" \
		"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/$helper" ||
		fail "$helper-content"
done
[ "$(grep -c '^development_console=' "$identity")" = 1 ] ||
	fail identity-development-console-count
case "$account_mode" in
	development-persistent)
		for path in /home/m1892-live/.config/kscreenlockerrc \
			/home/m1892-live/.config/powerdevilrc \
			/home/m1892-live/.config/kwalletrc \
			/home/m1892-live/.config/applications-blacklistrc \
			/home/m1892-live/.config/kglobalshortcutsrc \
			/home/m1892-live/.config/kwinrulesrc; do
			name=$(printf '%s' "$path" | tr '/' '_')
			debugfs -R "dump $path $work/root/$name" "$work/rootfs.ext4" >/dev/null 2>&1 ||
				fail "development-file:$path"
		done
		grep -Eq '^m1892-live:x:1000:1000:' "$work/root/_etc_passwd" || fail live-user
		grep -Eq '^m1892-live:!\*:20703:' "$work/root/_etc_shadow" || fail live-user-lock
		grep -Fxq 'Autolock=false' "$work/root/_home_m1892-live_.config_kscreenlockerrc" ||
			fail live-autolock-policy
		grep -Fxq 'LockOnResume=false' "$work/root/_home_m1892-live_.config_kscreenlockerrc" ||
			fail live-resume-lock-policy
		[ "$(grep -Fxc 'LockBeforeTurnOffDisplay=false' \
			"$work/root/_home_m1892-live_.config_powerdevilrc")" = 3 ] ||
			fail live-dpms-lock-policy
		grep -Fxq 'Enabled=false' "$work/root/_home_m1892-live_.config_kwalletrc" ||
			fail live-wallet-policy
		grep -Fxq 'First Use=false' "$work/root/_home_m1892-live_.config_kwalletrc" ||
			fail live-wallet-first-use-policy
		cmp -s "$work/root/_home_m1892-live_.config_kglobalshortcutsrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/kglobalshortcutsrc" ||
			fail live-power-key-shortcut-content
		cmp -s "$work/root/_home_m1892-live_.config_applications-blacklistrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/applications-blacklistrc" ||
			fail live-plasma-mobile-application-blacklist
		cmp -s "$work/root/_home_m1892-live_.config_kwinrulesrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/kwinrulesrc" ||
			fail live-gamescope-fullscreen-rule
		;;
	oem-owner)
		for path in \
			/etc/sddm.conf.d/90-m1892-oem-account.conf \
			/etc/polkit-1/rules.d/49-m1892-oem-setup.rules \
				/etc/xdg/autostart/m1892-oem-account-setup.desktop \
				/etc/NetworkManager/system-connections/m1892-cellular.nmconnection \
				/usr/local/share/applications/m1892-oem-account-setup.desktop \
				/usr/local/share/applications/calamares.desktop \
				/usr/share/polkit-1/actions/org.m1892.oem-account-setup.policy \
			/usr/share/m1892/calamares-oem/settings.conf \
			/usr/share/m1892/calamares-oem/modules/users.conf \
			/usr/share/m1892/calamares-oem/branding/default/branding.desc \
			/usr/share/calamares/branding/default/branding.desc \
			/usr/lib/aarch64-linux-gnu/calamares/modules/users/module.desc \
			/usr/lib/aarch64-linux-gnu/calamares/modules/users/libcalamares_viewmodule_users.so \
			/usr/share/mobile-broadband-provider-info/serviceproviders.xml \
			/var/lib/dpkg/info/mobile-broadband-provider-info.md5sums \
			/usr/share/m1892/calamares-oem/modules/displaymanager.conf \
			/usr/share/m1892/calamares-oem/modules/shellprocess-oem-prepare.conf \
			/usr/share/m1892/calamares-oem/modules/shellprocess-oem-finalize.conf \
			/usr/libexec/m1892/oem-account-setup-launcher \
			/usr/libexec/m1892/oem-calamares-wrapper \
			/usr/libexec/m1892/oem-owner-prepare \
			/usr/libexec/m1892/oem-owner-finalize \
			/usr/libexec/m1892/oem-setup-cleanup \
			/usr/libexec/m1892/oem-setup-recover \
			/usr/lib/sysusers.d/m1892-oem-setup.conf \
			/etc/systemd/system/m1892-oem-setup-cleanup.service \
			/etc/systemd/system/m1892-oem-setup-recovery.service \
			/var/lib/m1892-oem-setup/.config/plasmamobilerc \
			/var/lib/m1892-oem-setup/.config/applications-blacklistrc \
			/var/lib/m1892-oem-setup/.config/kglobalshortcutsrc \
			/var/lib/m1892-oem-setup/.config/kwinrulesrc; do
			name=$(printf '%s' "$path" | tr '/' '_')
			debugfs -R "dump $path $work/root/$name" "$work/rootfs.ext4" >/dev/null 2>&1 ||
				fail "oem-file:$path"
		done
		for path in \
				/etc/polkit-1/rules.d/49-m1892-oem-setup.rules \
				/etc/xdg/autostart/m1892-oem-account-setup.desktop \
				/usr/local/share/applications/m1892-oem-account-setup.desktop \
				/usr/local/share/applications/calamares.desktop \
				/usr/share/polkit-1/actions/org.m1892.oem-account-setup.policy \
			/usr/share/m1892/calamares-oem/settings.conf \
			/usr/share/m1892/calamares-oem/modules/users.conf \
			/usr/share/m1892/calamares-oem/modules/displaymanager.conf \
			/usr/share/m1892/calamares-oem/modules/shellprocess-oem-prepare.conf \
			/usr/share/m1892/calamares-oem/modules/shellprocess-oem-finalize.conf \
			/usr/libexec/m1892/oem-account-setup-launcher \
			/usr/libexec/m1892/oem-calamares-wrapper \
			/usr/libexec/m1892/oem-owner-prepare \
			/usr/libexec/m1892/oem-owner-finalize \
			/usr/libexec/m1892/oem-setup-cleanup \
			/usr/libexec/m1892/oem-setup-recover \
			/usr/lib/sysusers.d/m1892-oem-setup.conf \
			/etc/systemd/system/m1892-oem-setup-cleanup.service \
			/etc/systemd/system/m1892-oem-setup-recovery.service; do
			name=$(printf '%s' "$path" | tr '/' '_')
			canonical=$(dirname "$0")/../rootfs-overlay$path
			[ -f "$canonical" ] || fail "oem-canonical-file:$path"
			cmp -s "$work/root/$name" "$canonical" || fail "oem-file-content:$path"
		done
		! awk -F: '$3 >= 1000 && $3 < 65534 { found=1 } END { exit found ? 0 : 1 }' \
			"$work/root/_etc_passwd" || fail oem-regular-user-present
		setup_uid=$(awk -F: '$1 == "m1892-setup" { print $3 }' "$work/root/_etc_passwd")
		case "$setup_uid" in ''|*[!0-9]*) fail oem-setup-user ;; esac
		[ "$setup_uid" -lt 1000 ] || fail oem-setup-uid
		grep -Eq '^m1892-setup:(!\*|!|\*):' "$work/root/_etc_shadow" || fail oem-setup-lock
		! grep -q '^m1892-live:' "$work/root/_etc_passwd" || fail oem-development-user
		debugfs -R 'stat /home/m1892-live' "$work/rootfs.ext4" 2>/dev/null |
			grep -q '^Inode:' && fail oem-development-home
		settings=$work/root/_usr_share_m1892_calamares-oem_settings.conf
		debugfs -R 'stat /usr/share/m1892/calamares-oem/modules/usersq.conf' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' &&
			fail oem-usersq-module-present
		grep -Fxq 'dont-chroot: true' "$settings" || fail oem-dont-chroot
		grep -Fxq 'oem-setup: true' "$settings" || fail oem-setup-mode
		grep -Fxq 'disable-cancel: true' "$settings" || fail oem-cancel-policy
		grep -Fxq 'doAutologin: true' \
			"$work/root/_usr_share_m1892_calamares-oem_modules_users.conf" ||
			fail oem-autologin-policy
		python3 - "$work/root/_etc_passwd" "$work/root/_etc_group" \
			"$work/root/_usr_share_m1892_calamares-oem_modules_users.conf" <<'PY' ||
import json
import sys

def names(path):
    with open(path, encoding="utf-8") as stream:
        return {line.split(":", 1)[0] for line in stream if ":" in line}

with open(sys.argv[3], encoding="utf-8") as stream:
    text = stream.read()
section = text.split("\nuser:\n", 1)[1].split("\nhostname:\n", 1)[0]
line = next(line for line in section.splitlines() if line.startswith("  forbidden_names:"))
configured = json.loads(line.split(":", 1)[1].strip())
required = names(sys.argv[1]) | names(sys.argv[2]) | {"m1892-live"}
raise SystemExit(0 if len(configured) == len(set(configured)) and set(configured) == required else 1)
PY
			fail oem-forbidden-owner-names
		grep -Fxq 'branding: default' "$settings" || fail oem-mobile-branding-selection
		wrapper=$work/root/_usr_libexec_m1892_oem-calamares-wrapper
		grep -Fxq 'export QT_QPA_PLATFORM=wayland' "$wrapper" || fail oem-wayland-platform
		! grep -Eq '^export QT_(SCALE_FACTOR|SCREEN_SCALE_FACTORS)=' "$wrapper" ||
			fail oem-unsupported-qt-scale
		branding=$work/root/_usr_share_m1892_calamares-oem_branding_default_branding.desc
		default_branding=$work/root/_usr_share_calamares_branding_default_branding.desc
		grep -Eq '^componentName:[[:space:]]+default$' "$branding" ||
			fail oem-branding-name
		grep -Eq '^windowExpanding:[[:space:]]+fullscreen$' "$branding" ||
			fail oem-branding-window
		grep -Fxq 'sidebar: none' "$branding" || fail oem-branding-sidebar
		python3 - "$default_branding" "$branding" <<'PY' || fail oem-branding-descriptor-content
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
expected = source.replace(
    "windowExpanding:    normal", "windowExpanding:    fullscreen"
).replace("sidebar: widget", "sidebar: none")
raise SystemExit(0 if expected == pathlib.Path(sys.argv[2]).read_text(encoding="utf-8") else 1)
PY
		for asset in banner.png banner.png.license languages.png languages.png.license \
			show.qml squid.png squid.png.license stylesheet.qss \
			lang/calamares-default_ar.qm lang/calamares-default_en.qm \
			lang/calamares-default_eo.qm lang/calamares-default_fr.qm \
			lang/calamares-default_nl.qm; do
			name=$(printf '%s' "$asset" | tr '/' '_')
			debugfs -R "dump /usr/share/calamares/branding/default/$asset $work/root/default-$name" \
				"$work/rootfs.ext4" >/dev/null 2>&1 || fail "oem-branding-default-asset:$asset"
			debugfs -R "dump /usr/share/m1892/calamares-oem/branding/default/$asset $work/root/oem-$name" \
				"$work/rootfs.ext4" >/dev/null 2>&1 || fail "oem-branding-asset:$asset"
			cmp -s "$work/root/default-$name" "$work/root/oem-$name" ||
				fail "oem-branding-asset-content:$asset"
		done
		for forbidden in partition mount unpackfs fstab bootloader initramfs umount; do
			sed 's/#.*//' "$settings" |
				grep -Eq "(^|[^[:alnum:]_-])$forbidden([^[:alnum:]_-]|$)" &&
				fail "oem-dangerous-module:$forbidden"
		done
		grep -Fxq 'User=m1892-setup' "$work/root/_etc_sddm.conf.d_90-m1892-oem-account.conf" ||
			fail oem-sddm-user
		cmp -s "$work/root/_var_lib_m1892-oem-setup_.config_applications-blacklistrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/applications-blacklistrc" ||
			fail oem-plasma-mobile-application-blacklist
		grep -Fxq 'wizardRun=true' \
			"$work/root/_var_lib_m1892-oem-setup_.config_plasmamobilerc" ||
			fail oem-native-wizard-gate
		cmp -s "$work/root/_var_lib_m1892-oem-setup_.config_kglobalshortcutsrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/kglobalshortcutsrc" ||
			fail oem-setup-power-key-shortcut-content
		cmp -s "$work/root/_var_lib_m1892-oem-setup_.config_kwinrulesrc" \
			"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/kwinrulesrc" ||
			fail oem-setup-gamescope-fullscreen-rule
		! grep -Fq 'ConditionPathExists=!/var/lib/m1892/oem-setup-cleanup.pass' \
			"$work/root/_etc_systemd_system_m1892-oem-setup-cleanup.service" ||
			fail oem-cleanup-nonconvergent-condition
		calamares_hidden=$work/root/_usr_local_share_applications_calamares.desktop
		grep -Fxq 'NoDisplay=true' "$calamares_hidden" &&
			grep -Fxq 'Hidden=true' "$calamares_hidden" ||
			fail oem-calamares-hidden-override
		cellular=$work/root/_etc_NetworkManager_system-connections_m1892-cellular.nmconnection
		cellular_source=$(dirname "$0")/../../public-release/src/rootfs/fresh-overlay/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
		provider_db=$work/root/_usr_share_mobile-broadband-provider-info_serviceproviders.xml
		provider_md5sums=$work/root/_var_lib_dpkg_info_mobile-broadband-provider-info.md5sums
		provider_md5=$(awk '$2 == "usr/share/mobile-broadband-provider-info/serviceproviders.xml" { print $1 }' \
			"$provider_md5sums")
		[ "${#provider_md5}" = 32 ] &&
			[ "$(md5sum "$provider_db" | awk '{print $1}')" = "$provider_md5" ] ||
			fail oem-mobile-provider-database
		grep -Fxq 'carrier_neutral_cellular_profile=present' "$metadata" ||
			fail oem-generic-cellular-metadata
		grep -Fxq 'carrier_neutral_cellular_profile_sha256=edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0' \
			"$metadata" || fail oem-generic-cellular-metadata-hash
		[ -f "$cellular_source" ] && cmp -s "$cellular" "$cellular_source" ||
			fail oem-generic-cellular-profile
		[ "$(sha256sum "$cellular" | awk '{print $1}')" = \
			edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0 ] ||
			fail oem-generic-cellular-profile-hash
		! grep -Eiq '^(apn|username|password|password-flags|pin)=' "$cellular" ||
			fail oem-generic-cellular-secret
		debugfs -R 'stat /etc/NetworkManager/system-connections' "$work/rootfs.ext4" \
			>"$work/oem-network-dir-stat" 2>&1 || fail oem-network-directory
		grep -Eq 'Mode:[[:space:]]+0700' "$work/oem-network-dir-stat" &&
			grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
				"$work/oem-network-dir-stat" || fail oem-network-directory-metadata
		debugfs -R 'stat /etc/NetworkManager/system-connections/m1892-cellular.nmconnection' \
			"$work/rootfs.ext4" >"$work/oem-cellular-stat" 2>&1 || fail oem-cellular-stat
		grep -Eq 'Mode:[[:space:]]+0600' "$work/oem-cellular-stat" &&
			grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
				"$work/oem-cellular-stat" || fail oem-cellular-metadata
		debugfs -R 'ls -p /etc/NetworkManager/system-connections' "$work/rootfs.ext4" \
			>"$work/oem-network-profiles" 2>"$work/oem-network-profiles.stderr" ||
			fail oem-network-profile-list
		[ "$(grep '^/' "$work/oem-network-profiles" |
			grep -Ev '/\.\.?//$' | grep -c .)" = 1 ] &&
			grep -q '/m1892-cellular.nmconnection/' "$work/oem-network-profiles" ||
			fail oem-unexpected-network-profile
		for link in \
			/etc/systemd/system/graphical.target.wants/m1892-stage3-acceptance.service \
			/etc/systemd/system/graphical.target.wants/m1892-stage6-acceptance.service \
			/etc/systemd/system/multi-user.target.wants/m1892-oem-setup-cleanup.service; do
			debugfs -R "stat $link" "$work/rootfs.ext4" 2>/dev/null |
				grep -q '^Inode:' && fail "oem-premature-acceptance:$link"
		done
		for path in /var/lib/m1892/oem-owner-pending \
			/var/lib/m1892/oem-owner-created /var/lib/m1892/oem-setup-cleanup.pass; do
			debugfs -R "stat $path" "$work/rootfs.ext4" 2>/dev/null |
				grep -q '^Inode:' && fail "oem-premature-state:$path"
		done
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-oem-setup-recovery.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q 'Type: symlink' ||
			fail oem-recovery-service-link
		cmp -s "$work/root/_usr_libexec_m1892_oem-setup-recover" \
			"$(dirname "$0")/../rootfs-overlay/usr/libexec/m1892/oem-setup-recover" ||
			fail oem-recovery-script-content
		;;
esac
application_blacklist=$work/root/_etc_skel_.config_applications-blacklistrc
debugfs -R 'dump /etc/skel/.config/applications-blacklistrc /dev/stdout' \
	"$work/rootfs.ext4" >"$application_blacklist" 2>/dev/null ||
	fail plasma-mobile-application-blacklist
cmp -s "$application_blacklist" \
	"$(dirname "$0")/../rootfs-overlay/etc/skel/.config/applications-blacklistrc" ||
	fail plasma-mobile-application-blacklist-content
grep -Fxq 'settings_launcher=plasma-mobile-folio-user-blacklist' "$metadata" ||
	fail plasma-mobile-application-blacklist-metadata
debugfs -R 'stat /usr/share/icons/hicolor/scalable/apps/preferences-system.svg' \
	"$work/rootfs.ext4" 2>/dev/null | grep -Fq \
	'Fast link dest: "../../../breeze/apps/48/systemsettings.svg"' ||
	fail system-settings-icon-alias
debugfs -R 'stat /usr/lib/aarch64-linux-gnu/qt6/plugins/imageformats/libqsvg.so' \
	"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' ||
	fail qt6-svg-imageformat-plugin
debugfs -R 'stat /usr/lib/aarch64-linux-gnu/qt5/plugins/imageformats/libqsvg.so' \
	"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' ||
	fail maliit-qt5-svg-imageformat-plugin
debugfs -R 'stat /usr/lib/aarch64-linux-gnu/libcanberra-0.30/libcanberra-pulse.so' \
	"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' ||
	fail canberra-pulse-driver
wireplumber_hifi=$work/root/_etc_wireplumber_wireplumber.conf.d_51-m1892-hifi-format.conf
debugfs -R 'dump /etc/wireplumber/wireplumber.conf.d/51-m1892-hifi-format.conf /dev/stdout' \
	"$work/rootfs.ext4" >"$wireplumber_hifi" 2>/dev/null ||
	fail m1892-wireplumber-hifi-format
cmp -s "$wireplumber_hifi" \
	"$(dirname "$0")/../rootfs-overlay/etc/wireplumber/wireplumber.conf.d/51-m1892-hifi-format.conf" ||
	fail m1892-wireplumber-hifi-format-content
status=$work/root/_var_lib_dpkg_status
grep -Fxq 'initialstart_backend=distribution-default-hardware' "$metadata" || \
 fail initialstart-backend-metadata
grep -Fxq 'orientation_startup_order=iio-before-sddm' "$metadata" || \
 fail orientation-startup-order-metadata
if debugfs -R 'stat /usr/local/bin/plasma-mobile-initial-start' "$work/rootfs.ext4" 2>/dev/null | \
 grep -q '^Inode:'; then
	fail unexpected-initialstart-launcher
fi
debugfs -R 'stat /usr/bin/plasma-mobile-initial-start' "$work/rootfs.ext4" 2>/dev/null | \
 grep -Eq 'Mode:[[:space:]]+0755' || fail distribution-initialstart-binary
for package in e2fsprogs mobile-broadband-provider-info plasma-mobile-phone \
	plasma-dialer spacebar callaudiod mmsd-tng python3-gi gir1.2-qrtr-1.0 libqt5svg5; do
	awk -v wanted="$package" '
		$1 == "Package:" { current=$2 }
		$1 == "Status:" && current == wanted && $0 == "Status: install ok installed" { found=1 }
		END { exit(found ? 0 : 1) }
	' \
		"$status" || fail "package:$package"
done
grep -Fxq 'spacebar_scope=m1892-multi-bearer' "$metadata" || fail spacebar-scope
grep -Fxq 'ims_scope=clean-native' "$metadata" || fail ims-scope
[ "$(sed -n 's/^ims_voltd_no_main_default_patch_sha256=//p' "$metadata")" = \
	17b9a34eb2e4cc804c9ae1d45959eb372c85a3b9f48a7fa00223c5136922a4a5 ] ||
	fail ims-route-patch-metadata
for contract in \
	'ims_voltd_main_default_install=absent' \
	'ims_voltd_stale_main_default_cleanup=present' \
	'ims_voltd_ra_default_router_acceptance=disabled' \
	'ims_voltd_link_address_dad=preserved'; do
	grep -Fxq "$contract" "$metadata" || fail "ims-route-contract:$contract"
done
[ "$(sha256sum "$spacebar_input/spacebar-daemon" | awk '{print $1}')" = \
	"$(sed -n 's/^spacebar_sha256=//p' "$metadata")" ] || fail spacebar-metadata-hash
[ "$(sha256sum "$ims_input/SHA256SUMS" | awk '{print $1}')" = \
	"$(sed -n 's/^ims_runtime_manifest_sha256=//p' "$metadata")" ] ||
	fail ims-manifest-metadata-hash
(cd "$ims_input" && sha256sum -c SHA256SUMS >/dev/null) || fail ims-input-manifest
for contract in \
	'voltd_no_main_default_patch_sha256=17b9a34eb2e4cc804c9ae1d45959eb372c85a3b9f48a7fa00223c5136922a4a5' \
	'voltd_main_default_install=absent' \
	'voltd_stale_main_default_cleanup=present' \
	'voltd_ra_default_router_acceptance=disabled' \
	'voltd_link_address_dad=preserved'; do
	grep -Fxq "$contract" "$ims_input/BUILD-METADATA.txt" ||
		fail "ims-input-route-contract:$contract"
done
for path in \
	/usr/lib/aarch64-linux-gnu/libexec/spacebar-daemon \
	/opt/m1892-openimsd/lib/girepository-1.0/Qmi-1.0.typelib \
	/opt/m1892-openimsd/qcom-imsd/src/qcom_imsd/main.py \
	/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/libqmi-glib.so.5.12.0 \
	/opt/m1892-modemmanager/sbin/ModemManager \
	/usr/libexec/m1892/m1892-81voltd \
	/usr/libexec/m1892/qcom-imsd \
	/etc/NetworkManager/dispatcher.d/90-m1892-ims-online \
	/etc/systemd/system/ModemManager.service.d/20-m1892-ims-runtime.conf; do
	name=$(printf '%s' "$path" | tr '/' '_')
	debugfs -R "dump $path $work/root/$name" "$work/rootfs.ext4" >/dev/null 2>&1 ||
		fail "ims-image-file:$path"
done
spacebar=$work/root/_usr_lib_aarch64-linux-gnu_libexec_spacebar-daemon
[ "$(sha256sum "$spacebar" | awk '{print $1}')" = \
	"$(sha256sum "$spacebar_input/spacebar-daemon" | awk '{print $1}')" ] ||
	fail spacebar-image-hash
grep -aFq 'Ignoring IMS bearer for Spacebar data state:' "$spacebar" ||
	fail spacebar-ims-filter
! grep -aFq 'deleteBearer' "$spacebar" || fail spacebar-destructive-api
modemmanager=$work/root/_opt_m1892-modemmanager_sbin_ModemManager
voltd=$work/root/_usr_libexec_m1892_m1892-81voltd
strings "$voltd" | grep -Fxq '/proc/sys/net/ipv6/conf/%s/accept_ra_defrtr' ||
	fail ims-voltd-ra-policy
strings "$voltd" | grep -Fxq 'Removed stale IMS main-table defaults from %s' ||
	fail ims-voltd-route-cleanup
[ "$(sha256sum "$modemmanager" | awk '{print $1}')" = \
	"$(sha256sum "$ims_input/opt/m1892-modemmanager/sbin/ModemManager" | awk '{print $1}')" ] ||
	fail modemmanager-image-hash
dynamic=$(aarch64-linux-gnu-readelf -d "$modemmanager")
printf '%s\n' "$dynamic" | grep -Fq \
	'/opt/m1892-modemmanager/lib/aarch64-linux-gnu:/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu' ||
	fail modemmanager-runpath
grep -aFq 'qmi_message_wms_raw_send_input_set_sms_on_ims' "$modemmanager" ||
	fail modemmanager-sms-on-ims
qmi=$work/root/_opt_m1892-mm-libqmi_lib_aarch64-linux-gnu_libqmi-glib.so.5.12.0
strings "$qmi" | grep -Fq '/opt/m1892-mm-libqmi/libexec/qmi-proxy' ||
	fail qmi-proxy-path
strings "$qmi" | grep -Fq 'm1892-mm-libqmi-972' && fail qmi-development-prefix
qcom=$work/root/_opt_m1892-openimsd_qcom-imsd_src_qcom_imsd_main.py
grep -Fq 'Skipping destructive IMS reset; preserving active packet data' "$qcom" ||
	fail qcom-idempotent-reset
grep -Fq 'Required IMS services are already enabled' "$qcom" ||
	fail qcom-idempotent-config
grep -Fxq 'ExecStart=/opt/m1892-modemmanager/sbin/ModemManager' \
	"$work/root/_etc_systemd_system_ModemManager.service.d_20-m1892-ims-runtime.conf" ||
	fail modemmanager-service-override
case "$daily_packages" in
	''|none) ;;
	*)
		printf '%s' "$daily_packages" | tr ',' '\n' | while IFS= read -r package; do
			awk -v wanted="$package" '
				$1 == "Package:" { current=$2 }
				$1 == "Status:" && current == wanted && $0 == "Status: install ok installed" { found=1 }
				END { exit(found ? 0 : 1) }
			' "$status" || fail "daily-package:$package"
		done
		for path in /usr/bin/angelfish /usr/bin/qmlkonsole /usr/bin/dolphin \
			/usr/bin/plasma-systemmonitor /usr/bin/kdeconnect-cli /usr/bin/flatpak \
			/usr/bin/fastfetch /usr/bin/spectacle \
			/usr/bin/docker /usr/sbin/dockerd /usr/bin/retroarch \
			/usr/lib/aarch64-linux-gnu/libretro/gambatte_libretro.so \
			/usr/lib/aarch64-linux-gnu/libretro/mgba_libretro.so \
			/usr/lib/aarch64-linux-gnu/libretro/nestopia_libretro.so \
			/usr/libexec/m1892/docker-selftest /usr/libexec/m1892/stage6-acceptance \
			/etc/systemd/system/m1892-stage6-acceptance.service; do
			debugfs -R "stat $path" "$work/rootfs.ext4" 2>/dev/null |
				grep -q '^Inode:' || fail "daily-file:$path"
		done
		case "$account_mode" in
			development-persistent)
				debugfs -R 'cat /etc/group' "$work/rootfs.ext4" 2>/dev/null |
					grep -Eq '^docker:[^:]*:[0-9]+:([^,]+,)*m1892-live(,|$)' ||
					fail docker-group-user
				;;
			oem-owner)
				debugfs -R 'cat /etc/group' "$work/rootfs.ext4" 2>/dev/null |
					grep -E '^docker:' | grep -Eqv 'm1892-(live|setup)' ||
					fail oem-docker-group
				;;
		esac
		for link in \
			/etc/systemd/system/multi-user.target.wants/docker.service \
			/etc/systemd/system/multi-user.target.wants/containerd.service; do
			debugfs -R "stat $link" "$work/rootfs.ext4" 2>/dev/null |
				grep -q 'Type: symlink' || fail "daily-service-link:$link"
		done
		if [ "$account_mode" = development-persistent ]; then
			debugfs -R 'stat /etc/systemd/system/graphical.target.wants/m1892-stage6-acceptance.service' \
				"$work/rootfs.ext4" 2>/dev/null | grep -q 'Type: symlink' ||
				fail daily-acceptance-link
		fi
		;;
esac
plasma_settings_version=$(sed -n 's/^plasma_settings_version=//p' "$metadata")
[ "$plasma_settings_version" = 26.02.0-0m1892.1 ] || fail plasma-settings-metadata-version
awk -v wanted=plasma-settings -v version="$plasma_settings_version" '
	$1 == "Package:" { current=$2 }
	$1 == "Status:" && current == wanted && $0 == "Status: install ok installed" { installed=1 }
	$1 == "Version:" && current == wanted { found_version=$2 }
	END { exit(installed && found_version == version ? 0 : 1) }
' "$status" || fail plasma-settings-package-version
firstboot=$work/root/_usr_libexec_m1892_persistent-first-boot
grep -Fq 'readlink -f "$root_source"' "$firstboot" || fail firstboot-root-guard
grep -Fq 'partition-too-small' "$firstboot" || fail firstboot-size-guard
grep -Fq 'resize2fs /dev/sda19' "$firstboot" || fail firstboot-resize
grep -Fq 'systemd-machine-id-setup' "$firstboot" || fail firstboot-machine-id
grep -Fq 'ssh-keygen -A' "$firstboot" || fail firstboot-ssh-host-key-generation
grep -Fq 'ssh_host_*_key' "$firstboot" || fail firstboot-ssh-host-key-gate
development_ssh_key=$(sed -n 's/^development_ssh_key_injected=//p' "$metadata")
case "$development_ssh_key" in
	no)
		debugfs -R 'stat /root/.ssh/authorized_keys' "$work/rootfs.ext4" 2>/dev/null |
			grep -q '^Inode:' && fail unexpected-development-authorized-key
		;;
	yes)
		local_authorized_key=${M1892_STAGE3_AUTHORIZED_KEY:-}
		[ -f "$local_authorized_key" ] || fail development-authorized-key-input-absent
		key_sha=$(sed -n 's/^development_ssh_key_sha256=//p' "$metadata")
		[ "$(sha256sum "$local_authorized_key" | awk '{print $1}')" = "$key_sha" ] ||
			fail development-authorized-key-source-hash
		debugfs -R "dump /root/.ssh/authorized_keys $work/root/authorized_keys" \
			"$work/rootfs.ext4" >/dev/null 2>&1 || fail development-authorized-key-absent
		cmp -s "$work/root/authorized_keys" "$local_authorized_key" ||
			fail development-authorized-key-image-hash
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/ssh.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q 'Type: symlink' ||
			fail development-ssh-service-disabled
		;;
	*) fail invalid-development-ssh-key-metadata ;;
esac
if [ "$account_mode" = oem-owner ]; then
	[ "$development_ssh_key" = no ] || fail oem-development-ssh-key
	grep -Fxq 'private_network_injected=no' "$metadata" || fail oem-private-network
	debugfs -R 'stat /etc/NetworkManager/system-connections/m1892-local-test.nmconnection' \
		"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' && fail oem-private-profile
	debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/ssh.service' \
		"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' && fail oem-ssh-enabled
fi
acm_service=$work/root/_etc_systemd_system_m1892-stage3-acm-shell.service
grep -Fxq 'ConditionKernelCommandLine=m1892.usb=acm-ncm' "$acm_service" ||
	fail acm-usb-profile-condition
grep -Fxq 'ConditionPathExists=/dev/ttyGS0' "$acm_service" ||
	fail acm-device-condition
grep -Fq 'Requires=dev-ttyGS0.device' "$acm_service" && fail acm-device-pulled
grep -Fxq 'KillSignal=SIGHUP' "$acm_service" || fail acm-stop-signal
grep -Fxq 'SendSIGHUP=yes' "$acm_service" || fail acm-stop-hangup
grep -Fxq 'TimeoutStopSec=5s' "$acm_service" || fail acm-stop-timeout
case "$development_console" in
	acm-root-shell)
		[ "$(sed -n 's/^development_console=//p' "$identity")" = yes ] ||
			fail identity-development-console-value
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-stage3-acm-shell.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q 'Type: symlink' || fail acm-link
		;;
	disabled)
		[ "$(sed -n 's/^development_console=//p' "$identity")" = no ] ||
			fail identity-development-console-value
		debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-stage3-acm-shell.service' \
			"$work/rootfs.ext4" 2>/dev/null | grep -q '^Inode:' && fail unexpected-acm-link
		;;
	*) fail development-console-metadata ;;
esac
service=$work/root/_usr_share_dbus-1_services_org.mobian_project.CallAudio.service
grep -Fxq 'Exec=/usr/libexec/m1892/callaudiod' "$service" || fail callaudiod-service
[ "$(sha256sum "$work/root/_usr_libexec_m1892_q6voiced" | awk '{print $1}')" = \
	"$(sed -n 's/^q6voiced_sha256=//p' "$metadata")" ] || fail q6voiced-hash
[ "$(sha256sum "$work/root/_usr_libexec_m1892_callaudiod" | awk '{print $1}')" = \
	"$(sed -n 's/^callaudiod_sha256=//p' "$metadata")" ] || fail callaudiod-hash
debugfs -R 'stat /etc/systemd/system/multi-user.target.wants/m1892-persistent-first-boot.service' \
	"$work/rootfs.ext4" >"$work/firstboot-link" 2>&1 || fail firstboot-link
grep -q 'Type: symlink' "$work/firstboot-link" || fail firstboot-link-type

cat >"$evidence_dir/verification.env" <<EOF
result=pass
rootfs_sha256=$rootfs_sha
recovery_sha256=$(sha256sum "$recovery" | awk '{print $1}')
root_mode=persistent-userdata
account_mode=$account_mode
development_console=$development_console
filesystem_uuid=de131892-0000-4000-8000-000000000007
filesystem_label=M1892_DEB13
stock_tail_changed=no
userdata_write_performed=no
boot_write_performed=no
EOF
cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_STAGE7_VERIFY_PASS
