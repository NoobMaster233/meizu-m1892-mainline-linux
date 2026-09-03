#!/bin/sh
set -eu

bundle=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
payload=$bundle/payload
state_root=/var/lib/m1892/r6-userspace-overlay
retro_profile=/usr/share/libretro/autoconfig/udev/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg
daily_user= daily_uid= daily_gid= daily_home=
retro= retro_override= ppsspp=
fail() { echo "M1892_R6_OVERLAY_FAIL: $*" >&2; exit 1; }

usage()
{
	echo "usage: $0 --check | --install | --rollback STATE_DIRECTORY" >&2
	exit 2
}

verify_payload()
{
	(cd "$bundle" && sha256sum -c BUNDLE_MANIFEST.sha256 >/dev/null) || fail bundle-manifest
	while IFS="$(printf '\t')" read -r mode size expected target; do
		file=$payload$target
		test -f "$file" || fail "payload-missing:$target"
		test "$(stat -c '%a' "$file")" = "$mode" || fail "payload-mode:$target"
		test "$(stat -c '%s' "$file")" = "$size" || fail "payload-size:$target"
		test "$(sha256sum "$file" | awk '{print $1}')" = "$expected" || fail "payload-hash:$target"
	done <"$bundle/PAYLOAD_MANIFEST.tsv"
	while IFS="$(printf '\t')" read -r target expected; do
		test -L "$payload$target" || fail "payload-link-missing:$target"
		test "$(readlink "$payload$target")" = "$expected" || fail "payload-link:$target"
	done <"$bundle/SYMLINK_MANIFEST.tsv"
}

resolve_user()
{
	record=$(getent passwd | awk -F: '
		$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
			print; count++
		}
		END { if (count != 1) exit 1 }
	') || fail regular-user-count
	daily_user=$(printf '%s\n' "$record" | cut -d: -f1)
	daily_uid=$(printf '%s\n' "$record" | cut -d: -f3)
	daily_gid=$(printf '%s\n' "$record" | cut -d: -f4)
	daily_home=$(printf '%s\n' "$record" | cut -d: -f6)
	test -d "$daily_home" || fail daily-home-absent
	retro=$daily_home/.config/retroarch/retroarch.cfg
	retro_override=$daily_home/.config/retroarch/m1892-esde.cfg
	ppsspp=$daily_home/.config/ppsspp/PSP/SYSTEM/ppsspp.ini
}

preflight()
{
	test "$(id -u)" = 0 || fail root-required
	test "$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null)" = \
		'Meizu 16th Plus (M1892)' || fail wrong-model
	test "$(uname -r)" = 7.1.0-rc1-sdm845 || fail wrong-kernel-abi
	resolve_user
	for command in apk gsettings rc-update setpriv sha256sum tar; do
		command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
	done
	test -x /usr/bin/retroarch || fail missing-retroarch-base-package
	test -r "$retro" || fail missing-retroarch-config
	test -r "$ppsspp" || fail missing-ppsspp-config
	test -d /usr/local/share/es-de || fail missing-esde-runtime-base
	verify_payload
}

session_bus()
{
	phoc=$(pgrep -o -u "$daily_uid" -x phoc 2>/dev/null || true)
	test -n "$phoc" || fail phoc-not-running
	tr '\000' '\n' <"/proc/$phoc/environ" |
		sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p' | head -1
}

as_user()
{
	bus=$1
	shift
	setpriv --reuid="$daily_uid" --regid="$daily_gid" --init-groups \
		env HOME="$daily_home" USER="$daily_user" LOGNAME="$daily_user" \
		XDG_RUNTIME_DIR="/run/user/$daily_uid" DBUS_SESSION_BUS_ADDRESS="$bus" "$@"
}

set_cfg()
{
	file=$1 key=$2 value=$3
	if grep -q "^${key} = " "$file"; then
		sed -i "s#^${key} = .*#${key} = \"${value}\"#" "$file"
	else
		printf '%s = "%s"\n' "$key" "$value" >>"$file"
	fi
}

case ${1:-} in
--check)
	preflight
	echo M1892_R6_OVERLAY_CHECK_PASS
	;;
--install)
	preflight
	pgrep -x es-de >/dev/null 2>&1 && fail esde-running
	pgrep -x retroarch >/dev/null 2>&1 && fail retroarch-running
	pgrep -x PPSSPPSDL >/dev/null 2>&1 && fail ppsspp-running
	bus=$(session_bus)
	test -n "$bus" || fail session-bus
	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	state=$state_root/$stamp
	install -d -m 0700 "$state"
	backup_list=$state/backup-paths
	: >"$backup_list"
	for path in \
		/etc/m1892-release /usr/bin/phoc /usr/local/sbin/m1892-daily-health \
		/etc/modprobe.d/m1892-radio-order.conf \
		/usr/local/sbin/m1892-cellular-prepare /etc/init.d/m1892-cellular-prepare \
		/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.mdt \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.b00 \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.b01 \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.b02 \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.b03 \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.b04 \
		/usr/lib/firmware/qcom/venus-5.2 \
		/usr/lib/modules/7.1.0-rc1-sdm845/kernel/drivers/media/platform/qcom/venus/venus-core.ko \
		/usr/local/sbin/m1892-venus-coldload-r520 /etc/init.d/m1892-venus-coldload-r520 \
		/usr/local/sbin/m1892-venus-coldload-r521 /etc/init.d/m1892-venus-coldload-r521 \
		/usr/local/sbin/m1892-clock /usr/local/sbin/m1892-clock-r186-pmos \
		/etc/init.d/m1892-clock \
		/usr/local/sbin/m1892-power /etc/init.d/m1892-power \
		/etc/polkit-1/rules.d/47-m1892-power-actions.rules \
		/usr/local/sbin/m1892-sensors /etc/init.d/m1892-sensors \
		/etc/udev/rules.d/99-m1892-sensors-orientation-r217.rules \
		/usr/local/sbin/m1892-ufs-policy /etc/init.d/m1892-ufs-policy \
		/etc/sysctl.d/90-m1892-daily-hardening.conf \
		/usr/local/sbin/m1892-efi-rtc-wake-r331 /etc/init.d/m1892-efi-rtc-wake-r331 \
		/usr/local/sbin/m1892-typec-host-sink-limit-r411 \
		/etc/udev/rules.d/99-m1892-typec-host-sink-limit-r411.rules \
		/usr/local/sbin/m1892-suspend /usr/local/libexec/m1892-suspend-broker \
		/usr/local/bin/m1892-suspend /usr/share/applications/m1892-suspend.desktop \
		/usr/share/polkit-1/actions/org.meizu.m1892.suspend.policy \
		/usr/local/sbin/m1892-safe-restart /usr/local/libexec/m1892-safe-restart-broker \
		/usr/local/bin/m1892-safe-restart /usr/share/applications/m1892-safe-restart.desktop \
		/usr/share/polkit-1/actions/org.meizu.m1892.safe-restart.policy \
		/usr/local/sbin/m1892-safe-fastboot /usr/libexec/m1892/reboot-fastboot-frozen \
		/etc/init.d/m1892-speaker /etc/udev/rules.d/91-m1892-speaker.rules \
		/etc/pulse/default.pa.d/m1892-speaker.pa /usr/share/alsa/ucm2/Meizu/m1892 \
		/usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf \
		/usr/lib/m1892/speaker /usr/local/bin/es-de /usr/local/bin/m1892-es-de \
		/usr/local/bin/retroarch /usr/local/share/es-de \
		/usr/local/share/applications/org.es_de.frontend.desktop \
		/opt/m1892/sdl2-native /usr/local/bin/PPSSPPSDL \
		/usr/local/share/ppsspp /usr/local/share/applications/PPSSPPQt.desktop \
		/usr/local/share/applications/org.ppsspp.PPSSPPSDL.desktop \
		/usr/local/share/m1892-r6 "$retro_override" "$retro_profile"; do
		if test -e "$path" || test -L "$path"; then
			printf '%s\n' "${path#/}" >>"$backup_list"
		else
			printf '%s\n' "$path" >>"$state/absent-before"
		fi
	done
	tar -C / -czf "$state/files-before.tar.gz" -T "$backup_list"
	cp -a "$retro" "$state/retroarch.cfg.before"
	cp -a "$ppsspp" "$state/ppsspp.ini.before"
	{
		echo "idle-delay=$(as_user "$bus" gsettings get org.gnome.desktop.session idle-delay)"
		echo "lock-enabled=$(as_user "$bus" gsettings get org.gnome.desktop.screensaver lock-enabled)"
		echo "lock-delay=$(as_user "$bus" gsettings get org.gnome.desktop.screensaver lock-delay)"
		echo "sleep-inactive-ac-type=$(as_user "$bus" gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type)"
		echo "sleep-inactive-battery-type=$(as_user "$bus" gsettings get org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type)"
	} >"$state/gsettings-before"

		(cd "$payload" && tar -cf - .) | (cd / && tar -xf -)
		sed -i "/^\[initial_session\]/,/^$/ s/^user = .*/user = \"$daily_user\"/" \
			/etc/phrog/greetd-config.toml
		install -D -m 0644 -o "$daily_uid" -g "$daily_gid" \
			/usr/local/share/m1892-r6/retroarch/m1892-esde.cfg "$retro_override"
	install -D -m 0644 \
		/usr/local/share/m1892-r6/retroarch/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg "$retro_profile"
	for pair in \
		input_enable_hotkey_btn:15 input_menu_toggle_btn:8 input_exit_emulator_btn:16 \
		input_pause_toggle_btn:5 input_screenshot_btn:6 input_fps_toggle_btn:9 \
		input_save_state_btn:12 input_load_state_btn:11 input_state_slot_increase_btn:h0up \
		input_state_slot_decrease_btn:h0down input_rewind_btn:nul input_rewind_axis:+5 \
		input_hold_fast_forward_btn:nul input_hold_fast_forward_axis:nul \
		input_toggle_fast_forward_btn:nul input_toggle_fast_forward_axis:+4 \
		input_shader_prev_axis:nul input_shader_next_axis:nul quit_press_twice:true; do
		set_cfg "$retro" "${pair%%:*}" "${pair#*:}"
	done
	set_cfg "$retro" rewind_enable false
		chown "$daily_uid:$daily_gid" "$retro"
	sed -i 's/^Language = .*/Language = zh_CN/' "$ppsspp"
	grep -q '^Language = zh_CN$' "$ppsspp" || printf '\nLanguage = zh_CN\n' >>"$ppsspp"
		chown "$daily_uid:$daily_gid" "$ppsspp"

	rc-service m1892-screen-idle stop >/dev/null 2>&1 || true
	rc-update del m1892-screen-idle default >/dev/null 2>&1 || true
	# postmarketOS' generic swclock helper is hard-coded to rtc0. On M1892
	# rtc0 is the unreadable EFI RTC; m1892-clock is the validated rtc1 offset
	# owner, so running both paths only emits an I/O error and races time setup.
	rc-update del swclock-offset-boot boot >/dev/null 2>&1 || true
	rc-update del swclock-offset-shutdown shutdown >/dev/null 2>&1 || true
	for service in usb-signaller nftables postmarketos-zram-swap; do
		rc-service "$service" stop >/dev/null 2>&1 || true
		rc-update del "$service" default >/dev/null 2>&1 || true
	done
	rc-service m1892-venus-coldload-r520 stop >/dev/null 2>&1 || true
	rc-update del m1892-venus-coldload-r520 boot >/dev/null 2>&1 || true
	rm -f /etc/init.d/m1892-screen-idle /etc/runlevels/default/m1892-screen-idle \
		/usr/local/libexec/m1892-screen-idle.py /usr/local/sbin/m1892-screen-idle-launch \
		/etc/init.d/m1892-venus-coldload-r520 \
		/usr/local/sbin/m1892-venus-coldload-r520
	for service_runlevel in m1892-clock:boot m1892-efi-rtc-wake-r331:boot \
		m1892-rmtfs-shadow:boot m1892-radio-bootstrap:boot \
		m1892-cellular-prepare:default m1892-power:default m1892-sensors:default \
		m1892-speaker:default m1892-ufs-policy:default 81voltd:default q6voiced:default \
		m1892-venus-coldload-r521:boot; do
		rc-update add "${service_runlevel%%:*}" "${service_runlevel#*:}" >/dev/null
	done
	depmod -a 7.1.0-rc1-sdm845
	as_user "$bus" gsettings set org.gnome.desktop.session idle-delay 'uint32 120'
	as_user "$bus" gsettings set org.gnome.desktop.screensaver lock-enabled false
	as_user "$bus" gsettings set org.gnome.desktop.screensaver lock-delay 'uint32 0'
	as_user "$bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
	as_user "$bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
	udevadm control --reload-rules
	sysctl -p /etc/sysctl.d/90-m1892-daily-hardening.conf >/dev/null
	{
		echo release=2026.09-developer-preview.17
		echo installed_at="$(date -Iseconds)"
		echo backup="$state/files-before.tar.gz"
		echo reboot_required=yes
	} >"$state/result"
	sync
	echo "state=$state"
	echo M1892_USERSPACE_OVERLAY_INSTALL_PASS
	;;
--rollback)
	test $# -eq 2 || usage
	test "$(id -u)" = 0 || fail root-required
		test "$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null)" = \
			'Meizu 16th Plus (M1892)' || fail wrong-model
		resolve_user
	state=$2
	case $state in "$state_root"/*) ;; *) fail rollback-state-outside-root ;; esac
	test -r "$state/files-before.tar.gz" || fail rollback-backup-missing
	tar -C / -xzf "$state/files-before.tar.gz"
	if test -r "$state/absent-before"; then
		while read -r path; do
			case $path in /etc/*|/usr/*|/opt/*) rm -rf -- "$path" ;; *) fail "unsafe-absent-path:$path" ;; esac
		done <"$state/absent-before"
	fi
		install -m 0644 -o "$daily_uid" -g "$daily_gid" "$state/retroarch.cfg.before" "$retro"
		install -m 0644 -o "$daily_uid" -g "$daily_gid" "$state/ppsspp.ini.before" "$ppsspp"
	sync
	echo M1892_R6_OVERLAY_ROLLBACK_FILES_RESTORED_REBOOT_REQUIRED
	;;
*) usage ;;
esac
