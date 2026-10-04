#!/bin/sh
set -eu

image=${1:-}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
expected_uuid=3982b874-0ec0-57c4-a83b-37965b6be709
firmware_mode=${M1892_FIRMWARE_MODE:-complete}
expected_root_authorized_keys=${M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE:-}
pipeline_evidence=${M1892_PIPELINE_EVIDENCE_FILE:-}
fail() { echo "M1892_FRESH_IMAGE_VERIFY_FAIL: $*" >&2; exit 1; }
test -f "$image" || fail missing-image
test "$(id -u)" = 0 || fail root-required
case $firmware_mode in
	absent|complete) ;;
	*) fail "invalid-firmware-mode:$firmware_mode" ;;
esac

pipeline_attested=0
evidence_value()
{
	key=$1
	awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; n++ }
		END { if (n != 1) exit 1 }' "$pipeline_evidence"
}
if test -n "$pipeline_evidence"; then
	test -f "$pipeline_evidence" || fail missing-pipeline-evidence
	test "$(evidence_value format)" = m1892-image-pipeline-evidence-v1 ||
		fail pipeline-evidence-format
	test "$(evidence_value image)" = "$(readlink -f "$image")" ||
		fail pipeline-evidence-image
	test "$(evidence_value fingerprint)" = "$(stat -c '%d|%i|%s|%y|%z' "$image")" ||
		fail stale-pipeline-evidence
	test "$(evidence_value filesystem_clean)" = yes ||
		fail pipeline-evidence-filesystem
	test "$(evidence_value free_blocks_zeroed)" = yes ||
		fail pipeline-evidence-free-blocks
	test "$(evidence_value local_firmware_verify)" = pass ||
		fail pipeline-evidence-local-verify
	attested_image_sha256=$(evidence_value image_sha256)
	case $attested_image_sha256 in
		*[!0-9a-f]*|'') fail pipeline-evidence-image-hash ;;
	esac
	test "${#attested_image_sha256}" -eq 64 || fail pipeline-evidence-image-hash
	pipeline_attested=1
fi
if test "$pipeline_attested" = 0; then
	e2fsck -fn "$image" >/dev/null || fail filesystem
fi
tmp=$(mktemp -d)
normalized_expected_root_authorized_keys=
trap 'rm -f "$normalized_expected_root_authorized_keys" 2>/dev/null || true; find "$tmp" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM
if test -n "$expected_root_authorized_keys" &&
	grep -q "$(printf '\r')" "$expected_root_authorized_keys"; then
	normalized_expected_root_authorized_keys=$(mktemp)
	tr -d '\r' <"$expected_root_authorized_keys" >"$normalized_expected_root_authorized_keys"
	expected_root_authorized_keys=$normalized_expected_root_authorized_keys
fi
# Docker and other unprivileged build environments deliberately do not expose
# loop devices. Extract only the trees covered by this release contract. The
# verifier remains read-only; unrelated package payload is already attested by
# the apk database and the local-firmware verifier.
extract_batch=$tmp/debugfs-extract.batch
: >"$extract_batch"
for path in \
	/etc \
	/home \
	/root \
	/lib/apk \
	/usr/local/sbin \
	/usr/lib/firmware/qcom/sdm845/m1892 \
	/usr/lib/firmware/qcom/venus-5.2 \
	/var/lib/dbus; do
	mkdir -p "$tmp$(dirname -- "$path")"
	printf 'rdump %s %s%s\n' "$path" "$tmp" "$(dirname -- "$path")" >>"$extract_batch"
done
fresh_metadata=$script_dir/fresh-overlay-metadata.tsv
runtime_contract=
for candidate in \
	"$script_dir/../userspace-overlay/SOURCE_FILES.tsv" \
	"$script_dir/../runtime/SOURCE_FILES.tsv"; do
	test -r "$candidate" || continue
	runtime_contract=$candidate
	break
done
test -r "$fresh_metadata" || fail missing-fresh-overlay-metadata
test -n "$runtime_contract" || fail missing-runtime-contract
{
	awk -F '\t' '$1 !~ /^#/ && NF >= 2 { print $1 }' "$fresh_metadata"
	awk -F '\t' '$1 !~ /^#/ && NF >= 3 { print $2 }' "$runtime_contract"
	printf '%s\n' \
		/usr/bin/phoc \
		/usr/bin/phosh-osk-stevia \
		/usr/bin/rmtfs \
		/usr/lib/xtables/libxt_addrtype.so \
		/usr/libexec/docker/cli-plugins/docker-buildx \
		/usr/libexec/docker/cli-plugins/docker-compose \
		/usr/libexec/phrog-greetd-session \
		/usr/local/libexec/m1892-osk-focus-bridge-r235.py \
		/usr/local/bin/PPSSPPSDL \
		/usr/local/bin/es-de \
		/usr/local/bin/retroarch \
		/usr/local/share/es-de/resources/graphics/window_icon_256.png \
		/usr/sbin/tini-static \
		/usr/share/glib-2.0/schemas/99-m1892-phosh.gschema.override
} | sort -u | while IFS= read -r path; do
	case $path in
		/etc/*|/home/*|/root/*|/usr/local/sbin/*|/usr/lib/firmware/*) continue ;;
	esac
	mkdir -p "$tmp$(dirname -- "$path")"
	printf 'dump -p %s %s%s\n' "$path" "$tmp" "$path" >>"$extract_batch"
done
# One process avoids reopening the image for each path through Docker/WSL.
# Firmware-absent mode intentionally lacks a few listed paths; the assertions
# below distinguish expected absence from required content.
debugfs -f "$extract_batch" "$image" >/dev/null 2>&1 || fail filesystem-extract
rm -f "$extract_batch"

user_record=$(awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
' "$tmp/etc/passwd") || fail regular-user-count
user_name=$(printf '%s\n' "$user_record" | cut -d: -f1)
user_uid=$(printf '%s\n' "$user_record" | cut -d: -f3)
user_gid=$(printf '%s\n' "$user_record" | cut -d: -f4)
user_home=$(printf '%s\n' "$user_record" | cut -d: -f6)
awk -F: -v user="$user_name" '$1=="docker" {
	n=split($4, members, ","); for (i=1; i<=n; i++) if (members[i]==user) ok=1
} END { exit ok ? 0 : 1 }' "$tmp/etc/group" || fail docker-group-membership

tab=$(printf '\t')
while IFS="$tab" read -r target mode; do
	case $target in ''|'#'*) continue ;; esac
	test -f "$tmp$target" || fail "fresh-overlay-target:$target"
	test "$(stat -c %u:%g "$tmp$target")" = 0:0 ||
		fail "fresh-overlay-owner:$target"
	test "$(stat -c %a "$tmp$target")" = "${mode#0}" ||
		fail "fresh-overlay-mode:$target"
done <"$fresh_metadata"

# Reject host-filesystem metadata leakage.  Every runtime manifest target is a
# root-owned system file with an explicit mode; a user-writable compositor or
# session launcher is a release-blocking local privilege escalation.
while IFS="$tab" read -r source target mode component; do
	case $source in ''|'#'*) continue ;; esac
	test -f "$tmp$target" || fail "runtime-contract-target:$target"
	test "$(stat -c %u:%g "$tmp$target")" = 0:0 ||
		fail "runtime-contract-owner:$target"
	test "$(stat -c %a "$tmp$target")" = "${mode#0}" ||
		fail "runtime-contract-mode:$target"
done <"$runtime_contract"
test -d "$tmp$user_home" || fail user-home

test "$(blkid -s UUID -o value "$image")" = "$expected_uuid" || fail uuid
grep -qx "UUID=$expected_uuid / ext4 defaults 0 0" "$tmp/etc/fstab" || fail fstab
test "$(grep -c '^command = "/usr/local/libexec/m1892-phosh-session-r237"$' "$tmp/etc/phrog/greetd-config.toml")" = 1 || fail greetd-initial-session
test "$(grep -c '^command = "/usr/libexec/phrog-greetd-session"$' "$tmp/etc/phrog/greetd-config.toml")" = 1 || fail greetd-fallback-greeter
grep -A2 '^\[initial_session\]' "$tmp/etc/phrog/greetd-config.toml" |
	grep -qx "user = \"$user_name\"" || fail greetd-user
test -x "$tmp/usr/libexec/phrog-greetd-session" || fail phrog-greeter
grep -qx 'rc_need="elogind"' "$tmp/etc/conf.d/greetd" || fail greetd-elogind-dependency
test -x "$tmp/usr/local/libexec/m1892-phosh-session-r237" || fail phosh-session
grep -qx 'export XDG_CURRENT_DESKTOP=Phosh:GNOME' \
	"$tmp/usr/local/libexec/m1892-phosh-session-r237" || fail phosh-session-desktop-identity
grep -Fqx 'export XDG_DATA_DIRS="${XDG_DATA_DIRS:-/usr/local/share:/usr/share}:/var/lib/flatpak/exports/share:$HOME/.local/share/flatpak/exports/share"' \
	"$tmp/usr/local/libexec/m1892-phosh-session-r237" || fail phosh-session-data-dirs
grep -qx 'marker=/run/m1892-sensors-ready' \
	"$tmp/usr/local/libexec/m1892-phosh-session-r237" || fail phosh-session-sensor-marker
! grep -Fq '/run/m1892-sensors-r237-pass' \
	"$tmp/usr/local/libexec/m1892-phosh-session-r237" || fail phosh-session-obsolete-marker
test -x "$tmp/usr/local/sbin/m1892-clock-r186-pmos" || fail clock-implementation
test -L "$tmp/etc/runlevels/boot/m1892-venus-coldload-r521" || fail venus-service
test ! -L "$tmp/etc/runlevels/boot/swclock-offset-boot" || fail duplicate-rtc0-boot-clock
test ! -L "$tmp/etc/runlevels/shutdown/swclock-offset-shutdown" || fail duplicate-rtc0-shutdown-clock
test -x "$tmp/usr/local/sbin/m1892-venus-coldload-r521" || fail venus-helper
test "$(sha256sum "$tmp/usr/lib/modules/7.1.0-rc1-sdm845/kernel/drivers/media/platform/qcom/venus/venus-core.ko" | awk '{print $1}')" = \
	bf0ddd26da2bc194c1b63a26d8c461ccaa76fe5564c8849c92d3fe73ed682655 || fail venus-module
osk_desktop="$tmp$user_home/.local/share/applications/sm.puri.OSK0.desktop"
test -r "$osk_desktop" || fail osk-autostart-override
grep -qx 'Exec=/usr/bin/phosh-osk-stevia --allow-replacement' "$osk_desktop" || fail osk-command
grep -qx 'OnlyShowIn=GNOME;Phosh;' "$osk_desktop" || fail osk-desktops
! grep -q '^X-GNOME-HiddenUnderSystemd=' "$osk_desktop" || fail osk-systemd-only-suppression
fcitx_override="$tmp$user_home/.config/autostart/org.fcitx.Fcitx5.desktop"
test -r "$fcitx_override" || fail fcitx-autostart-override
grep -qx 'Hidden=true' "$fcitx_override" || fail fcitx-autostart-hidden
grep -qx 'X-GNOME-Autostart-enabled=false' "$fcitx_override" || fail fcitx-autostart-disabled
for desktop in org.fcitx.Fcitx5.desktop fcitx5-configtool.desktop org.gnome.Snapshot.desktop; do
	file="$tmp/usr/local/share/applications/$desktop"
	test -r "$file" || fail "desktop-cleanup:$desktop"
	grep -qx 'NoDisplay=true' "$file" || fail "desktop-cleanup-visible:$desktop"
done
phosh_override="$tmp$user_home/.config/autostart/mobi.phosh.Shell.desktop"
test -r "$phosh_override" || fail phosh-unlocked-autostart
grep -qx 'Exec=/usr/libexec/phosh -U' "$phosh_override" || fail phosh-unlocked-command
test "$(stat -c %u:%g "$phosh_override")" = "$user_uid:$user_gid" ||
	fail phosh-unlocked-owner
test ! -e "$tmp/usr/local/libexec/m1892-osk-focus-bridge-r235.py" || fail custom-osk-focus-bridge
test ! -e "$tmp$user_home/.config/autostart/m1892-osk-focus-bridge-r235.desktop" || fail custom-osk-focus-autostart
test -x "$tmp/usr/local/sbin/m1892-daily-health" || fail daily-health
test -x "$tmp/usr/local/sbin/m1892-docker-selftest" || fail docker-selftest
for helper in m1892-rmtfs-shadow m1892-radio-bootstrap; do
	test -x "$tmp/usr/local/sbin/$helper" || fail "radio-helper:$helper"
	test -x "$tmp/etc/init.d/$helper" || fail "radio-service:$helper"
	test -L "$tmp/etc/runlevels/boot/$helper" || fail "radio-runlevel:$helper"
	test "$(readlink "$tmp/etc/runlevels/boot/$helper")" = "/etc/init.d/$helper" ||
		fail "radio-runlevel-target:$helper"
done
test -f "$tmp/etc/modprobe.d/m1892-radio-order.conf" || fail radio-order
grep -Fxq 'softdep qcom_q6v5_mss pre: qcom_pd_mapper' \
	"$tmp/etc/modprobe.d/m1892-radio-order.conf" || fail radio-order-content
test -z "$(grep -Rl 'findmnt -n -o UUID /' "$tmp/usr/local/sbin"/m1892-* || true)" || fail runtime-uuid-whitelist
test -x "$tmp/usr/local/sbin/m1892-safe-fastboot" || fail safe-fastboot
grep -q '^root_uuid=' "$tmp/usr/local/sbin/m1892-safe-fastboot" ||
	fail safe-fastboot-diagnostic-uuid
! grep -q 'findmnt -n -o UUID /' "$tmp/usr/local/sbin/m1892-safe-fastboot" ||
	fail safe-fastboot-uuid-gate
first_boot="$tmp/etc/init.d/m1892-r6-first-boot"
test -x "$first_boot" || fail first-boot-helper
grep -qx 'root_device=/dev/sda19' "$first_boot" || fail first-boot-root-device
grep -qx 'root_min_bytes=8589934592' "$first_boot" || fail first-boot-minimum-capacity
grep -qx "root_uuid=$expected_uuid" "$first_boot" || fail first-boot-root-uuid
grep -q 'PARTNAME=userdata' "$first_boot" || fail first-boot-partition-role
grep -q '^[[:space:]]*! test "$(blockdev --getsize64 "$root_device")" -ge \\$' "$first_boot" ||
	fail first-boot-capacity-is-not-minimum-comparison
grep -q '^[[:space:]]*"$root_min_bytes"; then$' "$first_boot" ||
	fail first-boot-minimum-capacity-operand
grep -q 'resize2fs "$root_device"' "$first_boot" || fail first-boot-resize
grep -q 'm1892-persist-sensors-import --install' "$first_boot" || fail first-boot-persist-import
grep -q '^identity_marker=/var/lib/m1892/r6-first-boot-identity-complete$' "$first_boot" ||
	fail first-boot-identity-marker
grep -q '^[[:space:]]*after udev-trigger udev-settle$' "$first_boot" ||
	fail first-boot-udev-order
schema_line=$(grep -n '^[[:space:]]*! glib-compile-schemas /usr/share/glib-2.0/schemas' "$first_boot" | cut -d: -f1)
dconf_line=$(grep -n '^[[:space:]]*! dconf update' "$first_boot" | cut -d: -f1)
resize_line=$(grep -n '^[[:space:]]*if ! resize2fs' "$first_boot" | cut -d: -f1)
persist_line=$(grep -n '^[[:space:]]*if ! /usr/local/sbin/m1892-persist-sensors-import --install' "$first_boot" | cut -d: -f1)
test -n "$schema_line" && test -n "$dconf_line" && test -n "$resize_line" &&
	test -n "$persist_line" && test "$schema_line" -lt "$dconf_line" &&
	test "$dconf_line" -lt "$resize_line" && test "$resize_line" -lt "$persist_line" ||
	fail first-boot-schema-identity-resize-persist-order
! grep -Eq 'persist-sensors-import.*\|\|.*dconf update|dconf update.*\|\|.*persist-sensors-import' "$first_boot" ||
		fail first-boot-persist-identity-short-circuit
grep -q 'window_icon_256.png' "$first_boot" || fail first-boot-esde-icon-source
grep -q '/usr/share/icons/hicolor/256x256/apps/org.es_de.frontend.png' "$first_boot" ||
	fail first-boot-esde-icon-target
grep -q 'gtk4-update-icon-cache --force --quiet /usr/share/icons/hicolor' "$first_boot" ||
	fail first-boot-icon-cache
grep -q 'update-desktop-database /usr/share/applications' "$first_boot" ||
	fail first-boot-system-desktop-cache
grep -q 'update-desktop-database /usr/local/share/applications' "$first_boot" ||
	fail first-boot-local-desktop-cache
phosh_defaults=$tmp/usr/share/glib-2.0/schemas/99-m1892-phosh.gschema.override
test -r "$phosh_defaults" || fail phosh-defaults
grep -Fqx "favorites=['org.gnome.Calls.desktop', 'sm.puri.Chatty.desktop', 'firefox-esr.desktop']" \
	"$phosh_defaults" || fail phosh-default-favorites
grep -qx 'Icon=weather-clear-night-symbolic' \
	"$tmp/usr/share/applications/m1892-suspend.desktop" || fail suspend-icon
grep -qx 'Icon=org.es_de.frontend' \
	"$tmp/usr/local/share/applications/org.es_de.frontend.desktop" || fail esde-desktop-icon
grep -qx 'StartupWMClass=es-de' \
	"$tmp/usr/local/share/applications/org.es_de.frontend.desktop" || fail esde-desktop-window-class
test -r "$tmp/usr/local/share/es-de/resources/graphics/window_icon_256.png" ||
	fail esde-icon-source
test -x "$tmp/usr/local/sbin/m1892-persist-sensors-import" || fail persist-import-helper
grep -q 'registry/sns_reg_config' "$tmp/usr/local/sbin/m1892-persist-sensors-import" ||
	fail persist-import-sns-reg-map
for service in m1892-r6-first-boot m1892-cellular-prepare m1892-power m1892-sensors m1892-speaker m1892-ufs-policy q6voiced docker; do
	test -L "$tmp/etc/runlevels/default/$service" || fail "service:$service"
done
for package in docker docker-cli-buildx docker-cli-compose calls chatty \
	purple-mm-sms callaudiod q6voiced q6voiced-openrc; do
	grep -qx "P:$package" "$tmp/lib/apk/db/installed" || fail "package:$package"
done
for path in \
	/usr/lib/xtables/libxt_addrtype.so \
	/usr/libexec/docker/cli-plugins/docker-buildx \
	/usr/libexec/docker/cli-plugins/docker-compose \
	/usr/sbin/tini-static \
	/etc/containerd/config.toml; do
	test -f "$tmp$path" || fail "docker-payload:$path"
done
for service in usb-signaller nftables postmarketos-zram-swap; do
	test ! -e "$tmp/etc/runlevels/default/$service" || fail "disabled-service:$service"
done
grep -qx 'Exec=/bin/false' \
	"$tmp/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service" ||
	fail modemmanager-dbus-activation
if test "$firmware_mode" = complete; then
	test -L "$tmp/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn" ||
		fail wlanmdsp-link
	test "$(readlink "$tmp/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn")" = \
		../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn || fail wlanmdsp-link-target
	while read -r expected file; do
		test "$(sha256sum "$tmp/usr/lib/firmware/qcom/sdm845/m1892/$file" |
			awk '{print $1}')" = "$expected" || fail "ipa-firmware:$file"
	done <<'EOF'
d8fd2615f48155c05cdf3cfa05eb31b6b7c3beda210ea1e478dbe30231385b40 ipa_fws.mdt
dda6338c5a331cb8db31c806b93cfb77028a10291b5b9ad6172b6b6218d7fdc6 ipa_fws.b00
0c1f66ac47b965d5ce77a8f1860c69b7e26d07cd05957ee4a21ffa3fd66b3694 ipa_fws.b01
fc00e78a3e73909eb33e01591cb8758c66bb58d91283c8396fc3ffac97fd17ab ipa_fws.b02
14024088f436ebd24b097cb113b2177e12c939efdac0211d560c7cc498611507 ipa_fws.b03
8d572c4b4dee9572d90ab90137ec030331856bbfd8bf2e6ee315da4a5bab3373 ipa_fws.b04
EOF
	while read -r expected file; do
		test "$(sha256sum "$tmp/usr/lib/firmware/qcom/venus-5.2/$file" |
			awk '{print $1}')" = "$expected" || fail "venus-firmware:$file"
	done <<'EOF'
14c5ff36b505333f3ad58713ca5537295227fd0fbfcf7744633f3cce04c0a05a venus.mbn
2228be26411289cf94ebfd3f6c5ba3fc2dda985c5e825a784eeb2e74edb3ef0e venus.b00
25a14e6315b4abb2e89efbfc74eba8763a62834d24b71f3197e0e87558155204 venus.b01
8d7a4d34c60a74037e2c8f1696d0c9c28a65b20a991a6b9a000cc64531dc673b venus.b02
3a71d6dd6098005e0e9ffb3249e13dd1f60baebf53ad5e26440636d271f41159 venus.b03
43b09596e1496809aaa964b34c146580f0566c86bc9d7218a1288fd15fb93424 venus.b04
EOF
	grep -q '^P:firmware-meizu-m1892$' "$tmp/lib/apk/db/installed" ||
		fail firmware-package
else
	for path in \
		/usr/lib/firmware/qcom/sdm845/m1892/ipa_fws.mdt \
		/usr/lib/firmware/qcom/venus-5.2/venus.mbn \
		/usr/bin/rmtfs; do
		test ! -e "$tmp$path" || fail "proprietary-path:$path"
	done
	! grep -q '^P:firmware-meizu-m1892$' "$tmp/lib/apk/db/installed" ||
		fail firmware-package-present
	for package in rmtfs rmtfs-openrc rmtfs-udev; do
		! grep -q "^P:$package$" "$tmp/lib/apk/db/installed" ||
			fail "runtime-package-present:$package"
	done
fi
test ! -e "$tmp/etc/runlevels/default/m1892-screen-idle" || fail obsolete-screen-idle
test -x "$tmp/usr/local/bin/es-de" || fail es-de
test -x "$tmp/usr/local/bin/retroarch" || fail retroarch-wrapper
test -x "$tmp/usr/local/bin/PPSSPPSDL" || fail ppsspp
test -r "$tmp$user_home/ES-DE/settings/es_settings.xml" || fail esde-settings
grep -Fqx "<string name=\"ROMDirectory\" value=\"$user_home/ROMs\" />" \
	"$tmp$user_home/ES-DE/settings/es_settings.xml" || fail esde-rom-home
test -r "$tmp$user_home/.config/retroarch/retroarch.cfg" || fail retroarch-settings
test -r "$tmp$user_home/.config/ppsspp/PSP/SYSTEM/ppsspp.ini" || fail ppsspp-settings
bad_user_owner=$(find "$tmp$user_home" -xdev \
	\( ! -uid "$user_uid" -o ! -gid "$user_gid" \) -print -quit)
test -z "$bad_user_owner" || fail "user-owner:${bad_user_owner#$tmp}"
test ! -e "$tmp/etc/machine-id" || fail machine-id-present
test ! -e "$tmp/var/lib/dbus/machine-id" || fail dbus-machine-id-present
test -z "$(find "$tmp/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit)" || fail ssh-host-key
if test -n "$expected_root_authorized_keys"; then
	test -f "$expected_root_authorized_keys" || fail missing-expected-root-authorized-keys
	test -f "$tmp/root/.ssh/authorized_keys" || fail root-authorized-keys-absent
	cmp "$tmp/root/.ssh/authorized_keys" "$expected_root_authorized_keys" >/dev/null ||
		fail root-authorized-keys-content
	test "$(stat -c '%a:%u:%g' "$tmp/root/.ssh")" = 700:0:0 ||
		fail root-ssh-directory-metadata
	test "$(stat -c '%a:%u:%g' "$tmp/root/.ssh/authorized_keys")" = 600:0:0 ||
		fail root-authorized-keys-metadata
	test -z "$(find "$tmp/home" "$tmp/root" -type f \
		\( -name known_hosts -o -name 'id_*' -o \
		\( -name authorized_keys ! -path "$tmp/root/.ssh/authorized_keys" \) \) \
		-print -quit)" || fail unexpected-user-ssh-key
else
	test -z "$(find "$tmp/home" "$tmp/root" -type f \
		\( -name authorized_keys -o -name known_hosts -o -name 'id_*' \) \
		-print -quit)" || fail user-ssh-key
fi
profile=$tmp/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
test -f "$profile" || fail generic-cellular-profile
test "$(stat -c '%a:%u:%g' "$tmp/etc/NetworkManager/system-connections")" = 700:0:0 ||
	fail generic-cellular-profile-directory-metadata
test "$(stat -c %a "$profile")" = 600 || fail generic-cellular-profile-mode
test "$(stat -c '%u:%g' "$profile")" = 0:0 || fail generic-cellular-profile-owner
test "$(find "$tmp/etc/NetworkManager/system-connections" -type f | wc -l)" = 1 ||
	fail unexpected-network-profile
grep -qx 'id=m1892-cellular' "$profile" || fail cellular-profile-id
grep -qx 'type=gsm' "$profile" || fail cellular-profile-type
grep -qx 'autoconnect=true' "$profile" || fail cellular-profile-autoconnect
grep -qx 'autoconnect-priority=-10' "$profile" || fail cellular-profile-priority
grep -qx 'auto-config=true' "$profile" || fail cellular-profile-auto-config
test "$(grep -c '^route-metric=1200$' "$profile")" = 2 || fail cellular-profile-route-metric
if grep -Eiq '^(apn|username|password|password-flags|pin)=' "$profile"; then
	fail cellular-profile-contains-credential
fi
awk -F: -v user="$user_name" '$1=="root"||$1==user { if ($2 != "!") exit 1; n++ } END { exit n == 2 ? 0 : 1 }' "$tmp/etc/shadow" || fail password-lock
grep -RIlE 'BEGIN (OPENSSH|RSA) PRIVATE KEY' "$tmp/etc" "$tmp/home" "$tmp/root" 2>/dev/null | grep -q . && fail private-key || true
grep -q '^P:device-meizu-m1892$' "$tmp/lib/apk/db/installed" || fail device-package
grep -q '^P:linux-meizu-m1892$' "$tmp/lib/apk/db/installed" || fail kernel-package
stevia_version=$(awk 'BEGIN { RS=""; FS="\n" }
	$0 ~ /(^|\n)P:stevia(\n|$)/ {
		for (i=1; i<=NF; i++) if ($i ~ /^V:/) print substr($i,3)
	}' "$tmp/lib/apk/db/installed")
test "$stevia_version" = 0.57.0-r1 || fail "stevia-version:$stevia_version"
test "$(sha256sum "$tmp/usr/bin/phosh-osk-stevia" | awk '{print $1}')" = \
	4480288ac5932acae0c939ec6ee3143dac1ab36b02db1d8bec3991402f1914bb ||
	fail stevia-empty-app-id-fix-binary

echo "packages=$(grep -c '^P:' "$tmp/lib/apk/db/installed")"
echo "used_bytes=$(du -s -B1 "$tmp" | awk '{print $1}')"
echo "firmware_mode=$firmware_mode"
echo M1892_FRESH_IMAGE_VERIFY_PASS
