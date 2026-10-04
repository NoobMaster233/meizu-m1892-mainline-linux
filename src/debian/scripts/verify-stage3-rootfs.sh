#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
artifact=${1:-}
evidence_dir=${2:-}
config=${3:-$tree_dir/config/stage3.env}
[ -f "$artifact" ] && [ -n "$evidence_dir" ] && [ -r "$config" ] || {
	echo "usage: $0 STAGE3_ROOTFS_TAR ABSOLUTE_EVIDENCE_DIR [CONFIG]" >&2
	exit 2
}
[ -f "$artifact.sha256" ] || { echo 'M1892_DEBIAN_STAGE3_VERIFY_FAIL: sidecar-absent' >&2; exit 1; }
config=$(readlink -f "$config")
M1892_DEBIAN_CONFIG_DIR=$(dirname "$config")
export M1892_DEBIAN_CONFIG_DIR
(cd "$(dirname -- "$artifact")" && sha256sum -c "$(basename -- "$artifact").sha256") >/dev/null || {
	echo 'M1892_DEBIAN_STAGE3_VERIFY_FAIL: artifact-hash' >&2
	exit 1
}
artifact_sha=$(awk 'NR == 1 { print $1 }' "$artifact.sha256")
[ "${#artifact_sha}" -eq 64 ] || {
	echo 'M1892_DEBIAN_STAGE3_VERIFY_FAIL: invalid-sidecar' >&2
	exit 1
}

# shellcheck disable=SC1090
. "$config"
fail() { echo "M1892_DEBIAN_STAGE3_VERIFY_FAIL: $*" >&2; exit 1; }
mkdir -p "$evidence_dir"
work=$(mktemp -d /tmp/m1892-debian-stage3-verify.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
tar --no-same-owner --exclude='./dev/*' -xf "$artifact" -C "$work"

rootfs_bytes=$(du -sb "$work" | awk '{print $1}')
rootfs_blocks_kib=$(du -sk "$work" | awk '{print $1}')

grep -Fxq 'ID=debian' "$work/etc/os-release" || fail wrong-os
grep -Eq '^VERSION_ID="?13"?$' "$work/etc/os-release" || fail wrong-version
[ "$(readlink -f "$work/sbin/init")" = "$work/usr/lib/systemd/systemd" ] || fail wrong-init
[ -f "$work/etc/machine-id" ] && [ ! -s "$work/etc/machine-id" ] || fail machine-id-not-empty
[ ! -e "$work/etc/hostname" ] || fail hostname-present
[ "$(cat "$work/etc/default/locale")" = LANG=zh_CN.UTF-8 ] || fail default-locale
[ "$(cat "$work/etc/timezone")" = Asia/Shanghai ] || fail default-timezone
[ "$(readlink "$work/etc/localtime")" = /usr/share/zoneinfo/Asia/Shanghai ] || fail localtime-link
[ -d "$work/usr/share/wayland-sessions" ] || fail wayland-sessions-absent
find "$work/usr/share/wayland-sessions" -type f -maxdepth 1 -print >"$evidence_dir/wayland-sessions.txt"
grep -qi 'plasma.*mobile' "$evidence_dir/wayland-sessions.txt" || fail plasma-mobile-session-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/dri/msm_dri.so" ] || fail msm-dri-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so" ] || fail freedreno-vulkan-absent
[ -e "$work/usr/lib/systemd/system/sddm.service" ] || fail sddm-unit-absent
find "$work/usr/share/fonts" -type f -iname 'NotoSansCJK*' -print -quit |
	grep -q . || fail cjk-font-absent
find "$work/usr/share/fonts" -type f -iname 'NotoColorEmoji.ttf' -print -quit |
	grep -q . || fail color-emoji-font-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/qt6/qml/org/kde/kirigamiaddons/formcard/qmldir" ] ||
	fail kirigamiaddons-formcard-qml-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/qt5/plugins/platforms/libqwayland-generic.so" ] ||
	fail maliit-qt5-wayland-platform-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/qt5/plugins/imageformats/libqsvg.so" ] ||
	fail maliit-qt5-svg-imageformat-plugin-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/libcanberra-0.30/libcanberra-pulse.so" ] ||
	fail canberra-pulse-driver-absent
wireplumber_hifi=$work/etc/wireplumber/wireplumber.conf.d/51-m1892-hifi-format.conf
[ -f "$wireplumber_hifi" ] || fail m1892-wireplumber-hifi-format-absent
grep -Fq 'node.name = "alsa_output.platform-sound.HiFi__Speaker__sink"' \
	"$wireplumber_hifi" || fail m1892-wireplumber-speaker-match
grep -Fq 'node.name = "alsa_input.platform-sound.HiFi__Mic__source"' \
	"$wireplumber_hifi" || fail m1892-wireplumber-mic-match
[ "$(grep -Fc 'audio.format = "S16LE"' "$wireplumber_hifi")" = 1 ] ||
	fail m1892-wireplumber-s16-format
grep -Fq 'device.routes.default-source-volume = 0.042875' \
	"$wireplumber_hifi" || fail m1892-wireplumber-source-volume
[ -f "$work/usr/share/applications/org.kde.plasma.dialer.desktop" ] ||
	fail plasma-dialer-desktop-absent
[ -f "$work/usr/share/applications/org.kde.spacebar.desktop" ] ||
	fail spacebar-desktop-absent
[ -x "$work/usr/bin/callaudiod" ] &&
	[ -f "$work/usr/share/dbus-1/services/org.mobian_project.CallAudio.service" ] ||
	fail callaudiod-dbus-activation-absent

status=$work/var/lib/dpkg/status
printf '%s' "$M1892_STAGE3_REQUIRED_PACKAGES" | tr ',' '\n' | while IFS= read -r package; do
	awk -v wanted="$package" '
		$1 == "Package:" { package=$2 }
		$1 == "Status:" && package == wanted && $0 == "Status: install ok installed" { found=1 }
		END { exit(found ? 0 : 1) }
	' "$status" || fail "package-not-installed:$package"
done
if [ -n "${M1892_PLASMA_SETTINGS_VERSION:-}" ]; then
	awk -v wanted=plasma-settings -v expected="$M1892_PLASMA_SETTINGS_VERSION" '
		$1 == "Package:" { package=$2 }
		$1 == "Version:" && package == wanted && $2 == expected { version=1 }
		$1 == "Status:" && package == wanted && $0 == "Status: install ok installed" { installed=1 }
		END { exit(version && installed ? 0 : 1) }
	' "$status" || fail plasma-settings-version
fi
if [ -n "${M1892_DAILY_PACKAGES:-}" ]; then
	for binary in /usr/bin/angelfish /usr/bin/qmlkonsole /usr/bin/dolphin \
		/usr/bin/plasma-systemmonitor /usr/bin/kdeconnect-cli /usr/bin/flatpak \
		/usr/bin/fastfetch /usr/bin/spectacle \
		/usr/bin/docker /usr/sbin/dockerd /usr/bin/retroarch; do
		[ -x "$work$binary" ] || fail "daily-binary-absent:$binary"
	done
	for core in gambatte_libretro.so mgba_libretro.so nestopia_libretro.so; do
		[ -f "$work/usr/lib/aarch64-linux-gnu/libretro/$core" ] ||
			fail "libretro-core-absent:$core"
	done
	[ -f "$work/usr/lib/systemd/system/docker.service" ] || fail docker-unit-absent
	[ -f "$work/usr/lib/systemd/system/containerd.service" ] || fail containerd-unit-absent
fi
grep -RqsE '(^|[[:space:]])forky([[:space:]]|$)' "$work/etc/apt" &&
	fail runtime-forky-source-enabled
for contract in iio-sensor-proxy=3.9-1 libssc2=0.4.4-1 libssc-bin=0.4.4-1; do
	package=${contract%%=*}
	version=${contract#*=}
	awk -v wanted="$package" -v expected="$version" '
		$1 == "Package:" { package=$2 }
		$1 == "Version:" && package == wanted && $2 == expected { found=1 }
		END { exit(found ? 0 : 1) }
	' "$status" || fail "sensor-backport-version:$contract"
done
installed_version()
{
	awk -v wanted="$1" '
		$1 == "Package:" { package=$2 }
		$1 == "Version:" && package == wanted { print $2; exit }
	' "$status"
}
[ "$(installed_version iio-sensor-proxy)" = 3.9-1 ] || fail sensor-proxy-version
[ "$(installed_version libssc2)" = 0.4.4-1 ] || fail libssc-version
[ "$(installed_version libssc-bin)" = 0.4.4-1 ] || fail libssc-bin-version
for binary in /usr/sbin/wpa_supplicant /usr/bin/rmtfs /usr/bin/tqftpserv \
		/usr/bin/qrtr-ns /usr/bin/wireplumber /usr/libexec/rtkit-daemon \
	/usr/sbin/ModemManager /usr/sbin/iw /usr/bin/qmicli /usr/bin/hexagonrpcd /usr/bin/script; do
	[ -x "$work$binary" ] || fail "phone-runtime-absent:$binary"
done
for binary in /usr/bin/gst-launch-1.0 /usr/bin/gst-inspect-1.0 /usr/bin/v4l2-ctl; do
	[ -x "$work$binary" ] || fail "media-runtime-absent:$binary"
done
[ -f "$work/usr/lib/aarch64-linux-gnu/gstreamer-1.0/libgstvideo4linux2.so" ] ||
	fail gstreamer-v4l2-plugin-absent
[ -f "$work/usr/lib/aarch64-linux-gnu/qt6/plugins/imageformats/libqsvg.so" ] ||
	fail qt6-svg-imageformat-plugin-absent
[ -f "$work/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service" ] ||
	fail wpa-dbus-activation-absent
[ -f "$work/usr/lib/systemd/system/wpa_supplicant.service" ] ||
	fail wpa-systemd-unit-absent
[ ! -e "$work/usr/bin/pd-mapper" ] || fail duplicate-userspace-pd-mapper
grep -Fxq 'ExecStart=/usr/bin/rmtfs -r -P -s' \
	"$work/usr/lib/systemd/system/rmtfs.service" || fail rmtfs-read-only-policy
[ ! -e "$work/var/cache/ldconfig/aux-cache" ] || fail build-host-ldconfig-cache-present
[ ! -s "$work/var/log/dpkg.log" ] || fail build-host-dpkg-log-present

awk -F: '$3 >= 1000 && $3 != 65534 { exit 1 }' "$work/etc/passwd" || fail regular-user-present
awk -F: '$2 !~ /^[!*]/ { exit 1 }' "$work/etc/shadow" || fail unlocked-password-present
find "$work/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit | grep -q . && fail ssh-host-key-present
find "$work/etc/NetworkManager/system-connections" -mindepth 1 -print -quit 2>/dev/null | grep -q . && fail network-profile-present
find "$work/root" "$work/home" -path '*/.ssh/*' -print -quit 2>/dev/null | grep -q . && fail owner-ssh-data-present

if grep -RIlE 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|(^|[[:space:]])psk=|ssid=' \
	"$work/etc" "$work/root" "$work/home" 2>/dev/null | grep -q .; then
	fail private-material-pattern
fi

awk '
	BEGIN { RS=""; FS="\n"; OFS="\t" }
	{
		package=version=architecture=status=""
		for (i=1; i<=NF; i++) {
			if ($i ~ /^Package: /) package=substr($i,10)
			else if ($i ~ /^Version: /) version=substr($i,10)
			else if ($i ~ /^Architecture: /) architecture=substr($i,15)
			else if ($i ~ /^Status: /) status=substr($i,9)
		}
		if (status == "install ok installed") print package,version,architecture
	}
' "$status" | LC_ALL=C sort >"$evidence_dir/packages.tsv"

{
	printf 'result=pass\n'
	printf 'artifact_sha256=%s\n' "$artifact_sha"
	printf 'package_count=%s\n' "$(wc -l <"$evidence_dir/packages.tsv")"
	printf 'rootfs_bytes=%s\n' "$rootfs_bytes"
	printf 'rootfs_blocks_kib=%s\n' "$rootfs_blocks_kib"
	printf 'default_locale=zh_CN.UTF-8\n'
	printf 'default_timezone=Asia/Shanghai\n'
	printf 'owner_credentials_injected=no\n'
	printf 'private_network_injected=no\n'
	printf 'plasma_mobile_session=present\n'
	printf 'msm_freedreno_dri=present\n'
	printf 'freedreno_vulkan=present\n'
	printf 'sddm_unit=present\n'
	printf 'cjk_fonts=present\n'
	printf 'color_emoji_font=present\n'
	printf 'kirigamiaddons_formcard_qml=present\n'
	printf 'maliit_qt5_wayland_platform=present\n'
	printf 'maliit_qt5_svg_imageformat=present\n'
	printf 'plasma_phone_apps=present\n'
	printf 'callaudiod_dbus_activation=present\n'
	printf 'debian_phone_runtime=present\n'
	printf 'wifi_supplicant=present\n'
	printf 'rmtfs_storage_policy=read-only-shadow\n'
	if [ -n "${M1892_DAILY_PACKAGES:-}" ]; then
		printf 'daily_apps=present\n'
		printf 'docker_packages=present\n'
		printf 'retroarch_cores=gambatte,mgba,nestopia\n'
	fi
} >"$evidence_dir/verification.env"
cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_STAGE3_ROOTFS_VERIFY_PASS
