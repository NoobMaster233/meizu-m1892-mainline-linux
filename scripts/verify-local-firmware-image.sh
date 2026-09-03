#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

image=${1:-}
firmware_apk=${2:-}
runtime_dir=${3:-}
kernel_bundle=${4:-}
root_authorized_keys=${M1892_ROOT_AUTHORIZED_KEYS_FILE:-}
telephony_audio_archive=${M1892_TELEPHONY_AUDIO_ARCHIVE:-}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tree_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
[ -z "${E2FSPROGS_DIR:-}" ] || PATH=$E2FSPROGS_DIR:$PATH
export PATH
fail() { echo "M1892_LOCAL_FIRMWARE_VERIFY_FAIL: $*" >&2; exit 1; }
[ -f "$image" ] || fail missing-image
[ -f "$firmware_apk" ] || fail missing-firmware-apk
[ -d "$runtime_dir" ] || fail missing-rmtfs-apk-directory
[ -f "$kernel_bundle" ] || fail missing-public-kernel-bundle
[ "$(stat -c %s "$image")" = 8589934592 ] || fail image-size
[ -z "$root_authorized_keys" ] || {
	[ -f "$root_authorized_keys" ] || fail missing-root-authorized-keys
	[ "$(stat -c %s "$root_authorized_keys")" -le 65536 ] ||
		fail root-authorized-keys-too-large
	awk '
		/^[[:space:]]*($|#)/ { next }
		$1 ~ /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ { valid++; next }
		{ exit 1 }
		END { if (valid < 1) exit 1 }
	' "$root_authorized_keys" || fail invalid-root-authorized-keys
	root_authorized_keys=$(CDPATH='' cd -- "$(dirname -- "$root_authorized_keys")" && pwd)/$(basename -- "$root_authorized_keys")
}
for command in awk basename cat cut debugfs dirname e2fsck find grep head install mkdir \
	modinfo rm readlink sed sha256sum sort stat tar tr tune2fs wc zerofree; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 { print $2 }')
[ "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -1)" = 1.47.4 ] ||
	fail "e2fsprogs-too-old:$e2fs_version"

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-local-firmware-verify.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
if [ -n "$root_authorized_keys" ] && grep -q "$(printf '\r')" "$root_authorized_keys"; then
	tr -d '\r' <"$root_authorized_keys" >"$work/authorized_keys.normalized"
	root_authorized_keys=$work/authorized_keys.normalized
fi
install_root=$work/install
mkdir -p "$install_root"
kernel_root=$work/kernel
mkdir -p "$kernel_root"
tar -tzf "$kernel_bundle" | awk '
	/^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
	END { exit bad ? 1 : 0 }
' || fail unsafe-public-kernel-bundle
tar -C "$kernel_root" -xzf "$kernel_bundle"
kernel_manifest=$kernel_root/M1892-KERNEL-BUILD-MANIFEST.txt
[ -f "$kernel_manifest" ] || fail missing-public-kernel-manifest
kernel_manifest_value()
{
	key=$1
	awk -F= -v key="$key" '$1==key { if (++count > 1) exit 2; value=$2 }
		END { if (count != 1) exit 1; print value }' "$kernel_manifest" ||
		fail "public-kernel-manifest:$key"
}
[ "$(kernel_manifest_value format)" = m1892-public-k1-v1 ] ||
	fail public-kernel-manifest-format
[ "$(kernel_manifest_value upstream_commit)" = \
	85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8 ] || fail public-kernel-upstream
install_public_module()
{
	relative=$1 manifest_key=$2 module_name=$3 destination=$4
	source=$kernel_root/$relative
	[ -f "$source" ] || fail "public-kernel-module-missing:$relative"
	[ "$(sha256sum "$source" | awk '{print $1}')" = \
		"$(kernel_manifest_value "$manifest_key")" ] ||
		fail "public-kernel-module-hash:$relative"
	[ "$(modinfo -F name "$source")" = "$module_name" ] ||
		fail "public-kernel-module-name:$relative"
	[ "$(modinfo -F vermagic "$source")" = \
		'7.1.0-rc1-sdm845 SMP preempt mod_unload aarch64' ] ||
		fail "public-kernel-module-vermagic:$relative"
	install -D -m 0644 "$source" "$install_root/usr/lib/m1892/speaker/$destination"
}
firmware_apk=$(CDPATH='' cd -- "$(dirname -- "$firmware_apk")" && pwd)/$(basename -- "$firmware_apk")
runtime_dir=$(CDPATH='' cd -- "$runtime_dir" && pwd)
rmtfs_apk=$runtime_dir/rmtfs-1.3-r0.apk
rmtfs_openrc_apk=$runtime_dir/rmtfs-openrc-1.3-r0.apk
rmtfs_udev_apk=$runtime_dir/rmtfs-udev-1.3-r0.apk
telephony_archive=$runtime_dir/m1892-telephony-apks.tar.gz
[ -n "$telephony_audio_archive" ] ||
	telephony_audio_archive=$runtime_dir/m1892-telephony-audio-runtime.tar.gz
check_apk()
{
	expected=$1 path=$2
	[ -f "$path" ] || fail "missing-runtime-apk:$path"
	[ "$(sha256sum "$path" | awk '{print $1}')" = "$expected" ] ||
		fail "runtime-apk-hash:$path"
}
check_apk a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4 "$rmtfs_apk"
check_apk 5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769 "$rmtfs_openrc_apk"
check_apk 09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7 "$rmtfs_udev_apk"
[ -f "$telephony_archive" ] || fail missing-telephony-archive
[ "$(sha256sum "$telephony_archive" | awk '{print $1}')" = \
	05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b ] ||
	fail telephony-archive-hash
telephony_dir=$work/telephony-apks
mkdir -p "$telephony_dir"
tar -C "$telephony_dir" -xzf "$telephony_archive"
(cd "$telephony_dir" && sha256sum -c SHA256SUMS >/dev/null) ||
	fail telephony-inner-hashes
telephony_manifest_count=$(grep -Ec '^[A-Za-z0-9_.+:-]+=[^[:space:]]+$' \
	"$telephony_dir/PACKAGES")
telephony_apk_count=$(find "$telephony_dir" -maxdepth 1 -type f -name '*.apk' | wc -l)
[ "$telephony_apk_count" = "$telephony_manifest_count" ] ||
	fail "telephony-apk-count:$telephony_apk_count:$telephony_manifest_count"
while IFS== read -r package version; do
	case $package in ''|'#'*) continue ;; esac
	[ -f "$telephony_dir/$package-$version.apk" ] ||
		fail "telephony-package-file:$package-$version.apk"
done <"$telephony_dir/PACKAGES"
for package in calls chatty purple-mm-sms callaudiod \
	q6voiced q6voiced-openrc; do
	grep -q "^$package=" "$telephony_dir/PACKAGES" ||
		fail "telephony-package-manifest:$package"
done
for package in "$firmware_apk" "$rmtfs_apk" "$rmtfs_openrc_apk" "$rmtfs_udev_apk"; do
	if ! tar -xf "$package" -C "$install_root" 2>"$work/tar.log"; then
		sed -n '1,80p' "$work/tar.log" >&2
		fail "apk-extract:$package"
	fi
done
for package in "$telephony_dir"/*.apk; do
	if ! tar -xf "$package" -C "$install_root" 2>"$work/tar.log"; then
		sed -n '1,80p' "$work/tar.log" >&2
		fail "telephony-apk-extract:$package"
	fi
done
[ -f "$telephony_audio_archive" ] || fail missing-telephony-audio-runtime
"$script_dir/verify-m1892-telephony-audio-runtime.sh" "$telephony_audio_archive" >/dev/null
tar -C "$install_root" -xzf "$telephony_audio_archive"
telephony_audio_root=$work/telephony-audio-expected
mkdir -p "$telephony_audio_root"
tar -C "$telephony_audio_root" -xzf "$telephony_audio_archive"
(cd "$telephony_audio_root" && sha256sum -c MANIFEST.sha256 >/dev/null) ||
	fail telephony-audio-runtime-manifest
install_public_module drivers/firmware/cirrus/cs_dsp.ko \
	cs_dsp_sha256 cs_dsp cs_dsp.ko
install_public_module sound/soc/codecs/snd-soc-wm-adsp.ko \
	wm_adsp_sha256 snd_soc_wm_adsp snd-soc-wm-adsp.ko
install_public_module sound/soc/codecs/snd-soc-cs35l41-lib.ko \
	cs35l41_lib_sha256 snd_soc_cs35l41_lib snd-soc-cs35l41-lib.ko
install_public_module sound/soc/codecs/snd-soc-cs35l41.ko \
	cs35l41_sha256 snd_soc_cs35l41 snd-soc-cs35l41.ko
install_public_module sound/soc/codecs/snd-soc-cs35l41-spi.ko \
	cs35l41_spi_sha256 snd_soc_cs35l41_spi snd-soc-cs35l41-spi.ko
install_public_module sound/soc/qcom/snd-soc-sdm845.ko \
	sdm845_audio_sha256 snd_soc_sdm845 snd-soc-sdm845.ko
usr_file_count=$(find "$install_root/usr" -type f | wc -l)
[ "$usr_file_count" -gt 151 ] || fail apk-file-count
[ -L "$install_root/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn" ] ||
	fail apk-wlanmdsp-link
[ "$(readlink "$install_root/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn")" = \
  ../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn ] || fail apk-wlanmdsp-link-target
[ -f "$install_root/etc/conf.d/rmtfs" ] || fail rmtfs-conf-payload
[ -f "$install_root/etc/init.d/rmtfs" ] || fail rmtfs-openrc-payload
for target in /usr/bin/q6voiced \
	/usr/local/libexec/m1892-callaudiod \
	/usr/local/libexec/m1892-telephony-audio.build-info \
	/usr/share/dbus-1/services/org.mobian_project.CallAudio.service; do
	[ -f "$install_root$target" ] || fail "telephony-audio-runtime-file:$target"
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 ||
		fail "image-telephony-audio-runtime:$target"
	cmp -s "$install_root$target" "$work/current" ||
		fail "image-telephony-audio-runtime-content:$target"
done
while read -r expected relative; do
	case $relative in etc/*|opt/*|usr/*) ;; *) fail "telephony-audio-manifest-path:$relative" ;; esac
	rm -f "$work/current"
	debugfs -R "dump -p /$relative $work/current" "$image" >/dev/null 2>&1 ||
		fail "image-telephony-audio-manifest-file:/$relative"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = "$expected" ] ||
		fail "image-telephony-audio-manifest-content:/$relative"
done <"$telephony_audio_root/MANIFEST.sha256"
debugfs -R 'stat /opt/m1892-openimsd/lib/libqmi-glib.so.5' "$image" \
	>"$work/qmi-soname-stat" 2>&1 || fail image-qmi-soname-link
grep -q 'Type: symlink' "$work/qmi-soname-stat" || fail image-qmi-soname-link-type

e2fsck -fn "$image" >/dev/null || fail filesystem
! tune2fs -l "$image" | grep '^Filesystem features:.*\borphan_file\b' >/dev/null ||
	fail orphan-file-feature
debugfs -R "dump -p /lib/apk/db/installed $work/installed" "$image" >/dev/null 2>&1 ||
	fail image-apk-database
debugfs -R "dump -p /etc/apk/world $work/world" "$image" >/dev/null 2>&1 ||
	fail image-apk-world
debugfs -R "dump -p /etc/passwd $work/passwd" "$image" >/dev/null 2>&1 ||
	fail image-passwd
user_record=$(awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
' "$work/passwd") || fail regular-user-count
user_uid=$(printf '%s\n' "$user_record" | cut -d: -f3)
user_gid=$(printf '%s\n' "$user_record" | cut -d: -f4)
user_home=$(printf '%s\n' "$user_record" | cut -d: -f6)
case $user_home in /home/*) ;; *) fail invalid-user-home ;; esac
cellular_profile=$script_dir/../src/rootfs/fresh-overlay/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
[ -r "$cellular_profile" ] || fail missing-generic-cellular-profile-source
[ "$(sha256sum "$cellular_profile" | awk '{print $1}')" = \
	edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0 ] ||
	fail generic-cellular-profile-source-hash
[ "$(grep -c '^P:firmware-meizu-m1892$' "$work/installed")" = 1 ] ||
	fail package-record
firmware_identity=$(awk 'BEGIN { RS=""; FS="\n" }
  $0 ~ /(^|\n)P:firmware-meizu-m1892(\n|$)/ {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^V:/) version=substr($i,3)
      else if ($i ~ /^A:/) arch=substr($i,3)
    }
    print version ":" arch
  }' "$work/installed")
[ "$firmware_identity" = 20260831-r0:aarch64 ] || fail package-identity
for package in rmtfs rmtfs-openrc rmtfs-udev; do
	[ "$(grep -c "^P:$package$" "$work/installed")" = 1 ] || fail "package-record:$package"
	[ "$(grep -cx "$package" "$work/world")" = 1 ] || fail "package-world:$package"
	identity=$(awk -v wanted="$package" 'BEGIN { RS=""; FS="\n" }
	  { name=""; version="" }
	  { for (i=1; i<=NF; i++) {
	      if ($i ~ /^P:/) name=substr($i,3)
	      else if ($i ~ /^V:/) version=substr($i,3)
	    }
	    if (name==wanted) print version
	  }' "$work/installed")
	[ "$identity" = 1.3-r0 ] || fail "package-identity:$package"
done
while IFS='=' read -r package expected_version; do
	[ "$(grep -c "^P:$package$" "$work/installed")" = 1 ] ||
		fail "telephony-package-record:$package"
	[ "$(grep -cx "$package" "$work/world")" = 1 ] ||
		fail "telephony-package-world:$package"
	identity=$(awk -v wanted="$package" 'BEGIN { RS=""; FS="\n" }
	  { name=""; version="" }
	  { for (i=1; i<=NF; i++) {
	      if ($i ~ /^P:/) name=substr($i,3)
	      else if ($i ~ /^V:/) version=substr($i,3)
	    }
	    if (name==wanted) print version
	  }' "$work/installed")
	[ "$identity" = "$expected_version" ] ||
		fail "telephony-package-identity:$package:$identity"
done <"$telephony_dir/PACKAGES"

# Product voice routing must accompany the generic distribution packages.
debugfs -R 'cat /usr/share/q6voiced/q6voiced.conf' "$image" >"$work/q6voiced.conf" 2>/dev/null ||
	fail q6voiced-config
grep -qx 'q6voice_card=0' "$work/q6voiced.conf" || fail q6voiced-card
grep -qx 'q6voice_device=0' "$work/q6voiced.conf" || fail q6voiced-device
debugfs -R 'cat /usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf' \
	"$image" >"$work/ucm-top" 2>/dev/null || fail ucm-top
grep -Fq 'SectionUseCase."Voice Call"' "$work/ucm-top" || fail ucm-voice-verb
debugfs -R 'cat /usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf' \
	"$image" >"$work/ucm-hifi" 2>/dev/null || fail ucm-hifi
grep -Fq 'PlaybackPCM "hw:${CardId},1"' "$work/ucm-hifi" || fail ucm-hifi-pcm
debugfs -R 'cat /usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf' \
	"$image" >"$work/ucm-voice" 2>/dev/null || fail ucm-voice
grep -Fq 'QUAT_MI2S_RX Voice Mixer VoiceMMode1' "$work/ucm-voice" ||
	fail ucm-voice-playback-route
grep -Fq 'VoiceMMode1 Capture Mixer SLIMBUS_0_TX' "$work/ucm-voice" ||
	fail ucm-voice-capture-route
grep -Fq 'AIF1_CAP Mixer SLIM TX6' "$work/ucm-voice" ||
	fail ucm-voice-stable-mic-aif
grep -Fq "CDC_IF TX6 MUX' DEC6" "$work/ucm-voice" ||
	fail ucm-voice-stable-mic-decimator
grep -Fq "AMIC MUX6' ADC1" "$work/ucm-voice" ||
	fail ucm-voice-stable-mic-adc
grep -Fq 'PlaybackPCM "hw:${CardId},1"' "$work/ucm-voice" || fail ucm-voice-playback-pcm
grep -Fq 'CapturePCM "hw:${CardId},2"' "$work/ucm-voice" || fail ucm-voice-capture-pcm
debugfs -R 'cat /etc/init.d/q6voiced' "$image" >"$work/q6voiced-openrc" 2>/dev/null ||
	fail q6voiced-openrc
grep -Fq 'need dbus m1892-speaker' "$work/q6voiced-openrc" ||
	fail q6voiced-speaker-dependency
bluetooth_source_root=$script_dir/../src/runtime-inputs/userspace/bluetooth
[ -d "$bluetooth_source_root" ] || fail missing-bluetooth-source
for spec in \
	"/etc/init.d/bluetooth:bluetooth.openrc" \
	"/usr/local/sbin/m1892-bluetooth-identity:m1892-bluetooth-identity" \
	"/usr/local/sbin/m1892-bluetooth-selftest:m1892-bluetooth-selftest"; do
	target=${spec%%:*}
	source=${spec#*:}
	debugfs -R "cat $target" "$image" >"$work/bluetooth-current" 2>/dev/null ||
		fail "bluetooth-missing:$target"
	cmp -s "$bluetooth_source_root/$source" "$work/bluetooth-current" ||
		fail "bluetooth-content:$target"
	debugfs -R "stat $target" "$image" >"$work/bluetooth-stat" 2>&1 ||
		fail "bluetooth-stat:$target"
	grep -Eq 'Mode:.*0755' "$work/bluetooth-stat" || fail "bluetooth-mode:$target"
	done
debugfs -R 'cat /etc/init.d/bluetooth' "$image" >"$work/bluetooth-openrc" 2>/dev/null ||
	fail bluetooth-openrc
grep -Fq '/usr/local/sbin/m1892-bluetooth-identity' "$work/bluetooth-openrc" ||
	fail bluetooth-openrc-identity-hook
for spec in \
	"/usr/local/sbin/m1892-power:$script_dir/../src/runtime-inputs/userspace/daily/m1892-power" \
	"/etc/init.d/m1892-power:$script_dir/../src/runtime-inputs/userspace/daily/m1892-power.openrc" \
	"/usr/local/sbin/m1892-daily-health:$script_dir/../src/runtime-inputs/userspace/daily/m1892-daily-health" \
	"/usr/local/sbin/m1892-docker-selftest:$script_dir/../src/runtime-inputs/userspace/daily/m1892-docker-selftest"; do
	target=${spec%%:*}
	source=${spec#*:}
	[ -f "$source" ] || fail "missing-owner-runtime-source:$source"
	debugfs -R "cat $target" "$image" >"$work/owner-runtime-current" 2>/dev/null ||
		fail "owner-runtime-missing:$target"
	cmp -s "$source" "$work/owner-runtime-current" ||
		fail "owner-runtime-content:$target"
	debugfs -R "stat $target" "$image" >"$work/owner-runtime-stat" 2>&1 ||
		fail "owner-runtime-stat:$target"
	grep -Eq 'Mode:.*0755' "$work/owner-runtime-stat" ||
		fail "owner-runtime-mode:$target"
done
speaker_source=$script_dir/../src/runtime-inputs/m1892-userspace/openrc/m1892-speaker
[ -f "$speaker_source" ] || fail missing-speaker-openrc-source
debugfs -R 'cat /etc/init.d/m1892-speaker' "$image" >"$work/m1892-speaker" 2>/dev/null ||
	fail speaker-openrc
cmp -s "$speaker_source" "$work/m1892-speaker" || fail speaker-openrc-content
for name in snd-soc-cs35l41-lib.ko snd-soc-cs35l41.ko snd-soc-sdm845.ko; do
	grep -Fq "$name" "$work/m1892-speaker" || fail "speaker-openrc-module:$name"
done
if grep -Eq 'snd-soc-(cs35l41(-lib)?-r442|sdm845-r437)\.ko' "$work/m1892-speaker"; then
	fail speaker-openrc-historical-module-name
fi
debugfs -R 'stat /etc/runlevels/default/q6voiced' "$image" >"$work/q6voiced-runlevel" 2>&1 ||
	fail q6voiced-runlevel
grep -q 'Type: symlink' "$work/q6voiced-runlevel" || fail q6voiced-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/q6voiced"' "$work/q6voiced-runlevel" ||
	fail q6voiced-runlevel-target
debugfs -R 'stat /etc/runlevels/default/81voltd' "$image" >"$work/81voltd-runlevel" 2>&1 ||
	fail 81voltd-runlevel
grep -q 'Type: symlink' "$work/81voltd-runlevel" || fail 81voltd-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/81voltd"' "$work/81voltd-runlevel" ||
	fail 81voltd-runlevel-target
debugfs -R 'stat /etc/runlevels/default/m1892-qcom-imsd' "$image" \
	>"$work/qcom-imsd-runlevel" 2>&1 || fail qcom-imsd-runlevel
grep -q 'Type: symlink' "$work/qcom-imsd-runlevel" || fail qcom-imsd-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/m1892-qcom-imsd"' "$work/qcom-imsd-runlevel" ||
	fail qcom-imsd-runlevel-target
for desktop in org.gnome.Calls-daemon.desktop sm.puri.Chatty-daemon.desktop; do
	debugfs -R "cat /etc/xdg/autostart/$desktop" "$image" \
		>"$work/$desktop" 2>/dev/null || fail "telephony-autostart:$desktop"
	grep -q '^Exec=' "$work/$desktop" || fail "telephony-autostart-exec:$desktop"
	! grep -qx 'X-GNOME-HiddenUnderSystemd=true' "$work/$desktop" ||
		fail "telephony-autostart-hidden:$desktop"
done
telephony_policy=$script_dir/../src/runtime-inputs/userspace/telephony/48-m1892-telephony.rules
[ -f "$telephony_policy" ] || fail missing-telephony-polkit-source
debugfs -R 'cat /etc/polkit-1/rules.d/48-m1892-telephony.rules' "$image" \
	>"$work/48-m1892-telephony.rules" 2>/dev/null || fail telephony-polkit
cmp -s "$telephony_policy" "$work/48-m1892-telephony.rules" ||
	fail telephony-polkit-content

checked=0
find "$install_root/usr" -type f | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 ||
		fail "missing:$target"
	[ -f "$work/current" ] || fail "missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$source" | awk '{print $1}')" ] || fail "content:$target"
	checked=$((checked + 1))
	printf '%s\n' "$checked" >"$work/checked"
done
[ "$(cat "$work/checked")" = "$usr_file_count" ] || fail compared-file-count
for target in \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-lib-r442.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-r442.ko \
	/usr/lib/m1892/speaker/snd-soc-sdm845-r437.ko; do
	rm -f "$work/historical-module"
	debugfs -R "dump -p $target $work/historical-module" "$image" >/dev/null 2>&1 || true
	[ ! -e "$work/historical-module" ] || fail "historical-speaker-module:$target"
done
for expected_path in \
	13633048cd98816d8f2c1cbe8dcd00193f24953d7e52208a51cb51f96617e9b4:/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin \
	92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2:/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn; do
	expected=${expected_path%%:*}
	target=${expected_path#*:}
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 ||
		fail "accepted-wlan-missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = "$expected" ] ||
		fail "accepted-wlan-hash:$target"
done
wlanmdsp_link=/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn
debugfs -R "stat $wlanmdsp_link" "$image" >"$work/wlanmdsp-stat" 2>&1 ||
	fail missing-wlanmdsp-link
grep -q 'Type: symlink' "$work/wlanmdsp-stat" || fail wlanmdsp-link-type
grep -Fq 'Fast link dest: "../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn"' \
	"$work/wlanmdsp-stat" || fail wlanmdsp-link-target
for target in /etc/conf.d/rmtfs /etc/init.d/rmtfs; do
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 ||
		fail "missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$install_root$target" | awk '{print $1}')" ] || fail "content:$target"
done
release_metadata_source=$tree_root/src/runtime-inputs/userspace/daily/m1892-release
[ -f "$release_metadata_source" ] || fail missing-release-metadata-source
rm -f "$work/current"
debugfs -R "dump -p /etc/m1892-release $work/current" "$image" >/dev/null 2>&1 ||
	fail missing-release-metadata
[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
  "$(sha256sum "$release_metadata_source" | awk '{print $1}')" ] ||
	fail release-metadata-content

# A firmware-complete image is not radio-complete unless the open-source
# orchestration installed by the base-image stage is present and enabled.
# Keep this as an independent gate in addition to the base-image verifier.
daily=$script_dir/../src/userspace/daily
[ -d "$daily" ] || fail missing-daily-runtime-source
for spec in \
	"/etc/modprobe.d/m1892-radio-order.conf:$daily/m1892-radio-order.conf" \
	"/usr/local/sbin/m1892-rmtfs-shadow:$daily/m1892-rmtfs-shadow" \
	"/etc/init.d/m1892-rmtfs-shadow:$daily/m1892-rmtfs-shadow.openrc" \
	"/usr/local/sbin/m1892-radio-bootstrap:$daily/m1892-radio-bootstrap" \
	"/etc/init.d/m1892-radio-bootstrap:$daily/m1892-radio-bootstrap.openrc"; do
	target=${spec%%:*}
	source=${spec#*:}
	[ -f "$source" ] || fail "missing-radio-source:$source"
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 ||
		fail "missing-radio-runtime:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$source" | awk '{print $1}')" ] ||
		fail "radio-runtime-content:$target"
done
for link in /etc/runlevels/boot/m1892-rmtfs-shadow \
	/etc/runlevels/boot/m1892-radio-bootstrap; do
	debugfs -R "stat $link" "$image" >"$work/stat" 2>&1 ||
		fail "missing-radio-runlevel:$link"
	grep -q 'Type: symlink' "$work/stat" || fail "radio-runlevel-type:$link"
	grep -q "Fast link dest: \"/etc/init.d/${link##*/}\"" "$work/stat" ||
		fail "radio-runlevel-target:$link"
done

debugfs -R "dump -p /etc/m1892-fresh-image $work/marker" "$image" >/dev/null 2>&1 ||
	fail marker
grep -qx 'release=m1892-mainline-2026.09-developer-preview.17-owner-firmware' \
	"$work/marker" || fail marker-release
grep -qx 'firmware=owner-generated-flyme-8.1.9.0A-plus-linux-firmware-20260221' \
	"$work/marker" || fail marker-firmware
grep -qx 'radio-runtime=alpine-rmtfs-1.3-r0-plus-root-managed-bootstrap' \
	"$work/marker" || fail marker-radio-runtime
grep -qx 'telephony=m1892-81voltd-openimsd-gnome-calls-chatty-q6voiced-voicemmode1-sms-over-ims' \
	"$work/marker" || fail marker-telephony
grep -qx 'speaker-modules=source-built-public-kernel-bundle' \
	"$work/marker" || fail marker-speaker-modules
grep -qx 'input-method=stevia-standard-wayland-seat-fcitx-autostart-disabled' \
	"$work/marker" || fail marker-input-method
if [ -n "$root_authorized_keys" ]; then
	grep -qx 'privacy=absent-machine-id,no-host-keys,owner-root-public-key,generic-cellular-autoconfig-only,no-user-network-profiles' \
		"$work/marker" || fail marker-privacy-owner-key
else
	grep -qx 'privacy=absent-machine-id,no-host-keys,no-user-keys,generic-cellular-autoconfig-only,no-user-network-profiles' \
		"$work/marker" || fail marker-privacy-clean
fi
rm -f "$work/current"
profile_path=/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
debugfs -R "dump -p $profile_path $work/current" "$image" >/dev/null 2>&1 ||
	fail missing-generic-cellular-profile
cmp -s "$cellular_profile" "$work/current" || fail generic-cellular-profile-content
debugfs -R 'ls -p /etc/NetworkManager/system-connections' "$image" \
	>"$work/network-profiles" 2>/dev/null || fail network-profile-list
[ "$(grep -Ev '/\.\.?//$' "$work/network-profiles" | grep -c .)" = 1 ] ||
	fail unexpected-network-profile
debugfs -R 'stat /etc/NetworkManager/system-connections' "$image" \
	>"$work/nm-system-connections-stat" 2>&1 || fail nm-system-connections-stat
debugfs -R "stat $profile_path" "$image" >"$work/cellular-profile-stat" 2>&1 ||
	fail cellular-profile-stat
grep -Eq 'Mode:[[:space:]]+0700' "$work/nm-system-connections-stat" ||
	fail nm-system-connections-mode
grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
	"$work/nm-system-connections-stat" || fail nm-system-connections-owner
grep -Eq 'Mode:[[:space:]]+0600' "$work/cellular-profile-stat" ||
	fail generic-cellular-profile-mode
grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
	"$work/cellular-profile-stat" || fail generic-cellular-profile-owner
osk_override=$user_home/.config/autostart/org.fcitx.Fcitx5.desktop
debugfs -R "dump -p $osk_override $work/fcitx-override" "$image" >/dev/null 2>&1 ||
	fail missing-fcitx-autostart-override
[ "$(sha256sum "$work/fcitx-override" | awk '{print $1}')" = \
	e0e873e90ec43cbdd44d0eb34109367ce4a1533da10375ba55ad96c2227ca69d ] ||
	fail fcitx-autostart-override-hash
grep -qx 'Hidden=true' "$work/fcitx-override" || fail fcitx-autostart-hidden
grep -qx 'X-GNOME-Autostart-enabled=false' "$work/fcitx-override" ||
	fail fcitx-autostart-disabled
debugfs -R "stat $osk_override" "$image" >"$work/fcitx-stat" 2>&1 ||
	fail fcitx-autostart-stat
grep -Eq "User:[[:space:]]+$user_uid[[:space:]]+Group:[[:space:]]+$user_gid([[:space:]]|$)" \
	"$work/fcitx-stat" || fail fcitx-autostart-owner
for path in /usr/local/libexec/m1892-osk-focus-bridge-r235.py \
	$user_home/.config/autostart/m1892-osk-focus-bridge-r235.desktop; do
	debugfs -R "stat $path" "$image" >"$work/stat" 2>&1 || true
	grep -q 'File not found' "$work/stat" || fail "custom-osk-bridge:$path"
done
for path in /etc/machine-id /var/lib/dbus/machine-id $user_home/.ssh; do
	debugfs -R "stat $path" "$image" >"$work/stat" 2>&1 || true
	grep -q 'File not found' "$work/stat" || fail "private-path:$path"
done
if [ -n "$root_authorized_keys" ]; then
	rm -f "$work/current"
	debugfs -R "dump -p /root/.ssh/authorized_keys $work/current" "$image" \
		>/dev/null 2>&1 || fail missing-root-authorized-keys-output
	cmp -s "$root_authorized_keys" "$work/current" ||
		fail content-root-authorized-keys-output
	debugfs -R 'stat /root/.ssh' "$image" >"$work/root-ssh-stat" 2>&1 ||
		fail root-ssh-stat
	debugfs -R 'stat /root/.ssh/authorized_keys' "$image" \
		>"$work/root-authorized-keys-stat" 2>&1 || fail root-authorized-keys-stat
	grep -Eq 'Mode:[[:space:]]+0700' "$work/root-ssh-stat" || fail root-ssh-mode
	grep -Eq 'Mode:[[:space:]]+0600' "$work/root-authorized-keys-stat" ||
		fail root-authorized-keys-mode
	grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
		"$work/root-authorized-keys-stat" || fail root-authorized-keys-owner
else
	debugfs -R 'stat /root/.ssh' "$image" >"$work/stat" 2>&1 || true
	grep -q 'File not found' "$work/stat" || fail private-path:/root/.ssh
fi
# The firmware package owns the empty destination directory so first boot can
# import this handset's calibration.  Reject content, not that empty mountpoint.
registry=/usr/share/qcom/sdm845/Meizu/m1892/sensors/registry
debugfs -R "ls -p $registry" "$image" >"$work/registry" 2>/dev/null ||
	fail missing-calibration-directory
grep -v '^$' "$work/registry" >"$work/registry.entries"
[ "$(wc -l <"$work/registry.entries")" = 2 ] || fail factory-calibration-content
grep -q '/\.//' "$work/registry.entries" || fail calibration-dot-entry
grep -q '/\.\.//' "$work/registry.entries" || fail calibration-dotdot-entry

# Run the full free-block disclosure gate last: it is the most expensive scan
# on a Windows-backed workspace and should not hide a cheap structural failure.
zero_report=$(zerofree -n -v "$image" 2>/dev/null | tr -d '\r')
[ "${zero_report%%/*}" = 0 ] || fail "nonzero-free-blocks:$zero_report"

echo "image_sha256=$(sha256sum "$image" | awk '{print $1}')"
echo M1892_LOCAL_FIRMWARE_VERIFY_PASS
