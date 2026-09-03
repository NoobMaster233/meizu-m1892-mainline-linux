#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
firmware_apk=${2:-}
runtime_dir=${3:-}
kernel_bundle=${4:-}
output=${5:-}
preseeded=${M1892_PRESEEDED_OUTPUT:-0}
root_authorized_keys=${M1892_ROOT_AUTHORIZED_KEYS_FILE:-}
telephony_audio_archive=${M1892_TELEPHONY_AUDIO_ARCHIVE:-}
normalized_authorized_keys=
cleanup_normalized_authorized_keys()
{
	[ -z "$normalized_authorized_keys" ] || rm -f "$normalized_authorized_keys"
}
trap cleanup_normalized_authorized_keys EXIT HUP INT TERM
# Current privacy-clean public base after the rebuilt userspace overlay and the
# finalizer's generic-user/ownership/identity gates.  Keep this content pin so
# owner firmware can never be injected into an unreviewed filesystem.
expected_base=dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46
expected_size=8589934592
[ -z "${E2FSPROGS_DIR:-}" ] || PATH=$E2FSPROGS_DIR:$PATH
export PATH
fail() { echo "M1892_LOCAL_FIRMWARE_IMAGE_FAIL: $*" >&2; exit 1; }
fsck_repair()
{
	status=0
	e2fsck -fy "$1" >/dev/null || status=$?
	case $status in
		0|1) ;;
		*) fail "filesystem-repair:$status" ;;
	esac
}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tree_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
fcitx_override=$tree_root/src/rootfs/fresh-overlay/etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop
[ -r "$fcitx_override" ] || fail missing-fcitx-autostart-override
[ "$(sha256sum "$fcitx_override" | awk '{print $1}')" = \
	e0e873e90ec43cbdd44d0eb34109367ce4a1533da10375ba55ad96c2227ca69d ] ||
	fail fcitx-autostart-override-hash
cellular_profile=$tree_root/src/rootfs/fresh-overlay/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
[ -r "$cellular_profile" ] || fail missing-generic-cellular-profile
[ "$(sha256sum "$cellular_profile" | awk '{print $1}')" = \
	edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0 ] ||
	fail generic-cellular-profile-hash
grep -qx 'id=m1892-cellular' "$cellular_profile" || fail generic-cellular-profile-id
grep -qx 'type=gsm' "$cellular_profile" || fail generic-cellular-profile-type
grep -qx 'autoconnect=true' "$cellular_profile" || fail generic-cellular-profile-autoconnect
grep -qx 'auto-config=true' "$cellular_profile" || fail generic-cellular-profile-auto-config
! grep -Eiq '^(apn|username|password|password-flags|pin)=' "$cellular_profile" ||
	fail generic-cellular-profile-contains-credential
[ -f "$base" ] || fail missing-public-base
[ -f "$firmware_apk" ] || fail missing-firmware-apk
[ -d "$runtime_dir" ] || fail missing-rmtfs-apk-directory
[ -f "$kernel_bundle" ] || fail missing-public-kernel-bundle
[ -n "$output" ] || fail missing-output-image
case "$preseeded" in 0|1) ;; *) fail invalid-preseeded-setting ;; esac
[ "$preseeded" = 1 ] || [ ! -e "$output" ] || fail output-exists
[ -z "$root_authorized_keys" ] || {
	[ -f "$root_authorized_keys" ] || fail missing-root-authorized-keys
	[ "$(stat -c %s "$root_authorized_keys")" -le 65536 ] ||
		fail root-authorized-keys-too-large
	if grep -q "$(printf '\r')" "$root_authorized_keys"; then
		normalized_authorized_keys=$(mktemp "${TMPDIR:-/tmp}/m1892-authorized-keys.XXXXXX")
		tr -d '\r' <"$root_authorized_keys" >"$normalized_authorized_keys"
		root_authorized_keys=$normalized_authorized_keys
	fi
	awk '
		/^[[:space:]]*($|#)/ { next }
		$1 ~ /^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)$/ { valid++; next }
		{ exit 1 }
		END { if (valid < 1) exit 1 }
	' "$root_authorized_keys" || fail invalid-root-authorized-keys
	root_authorized_keys=$(CDPATH='' cd -- "$(dirname -- "$root_authorized_keys")" && pwd)/$(basename -- "$root_authorized_keys")
}
[ "$(stat -c %s "$base")" = "$expected_size" ] || fail base-size
[ "$(sha256sum "$base" | awk '{print $1}')" = "$expected_base" ] || fail base-hash
for command in apk awk basename cat cmp comm cp cut debugfs dirname e2fsck find grep head \
	install mkdir modinfo readlink rm sed sha256sum sort stat tar tune2fs wc zerofree; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 { print $2 }')
[ "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -1)" = 1.47.4 ] ||
	fail "e2fsprogs-too-old:$e2fs_version"
apk_version=$(apk --version 2>&1 | awk '{ print $2; exit }' | sed 's/-r.*//')
[ "$(printf '%s\n' 3.0.0 "$apk_version" | sort -V | head -1)" = 3.0.0 ] ||
	fail "apk-tools-too-old:$apk_version"

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-local-firmware-image.XXXXXX")
keep_work=${M1892_KEEP_WORK:-0}
case $keep_work in 0|1) ;; *) fail invalid-keep-work-setting ;; esac
cleanup()
{
	if [ "$keep_work" = 1 ]; then
		echo "M1892_LOCAL_FIRMWARE_IMAGE_WORK=$work" >&2
	else
		find "$work" -depth -delete 2>/dev/null || true
	fi
	cleanup_normalized_authorized_keys
}
trap cleanup EXIT HUP INT TERM
install_root=$work/install
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
for spec in \
	"kernel_sha256:arch/arm64/boot/Image.gz" \
	"dtb_sha256:arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb"; do
	key=${spec%%:*}
	relative=${spec#*:}
	file=$kernel_root/$relative
	[ -f "$file" ] || fail "public-kernel-missing:$relative"
	[ "$(sha256sum "$file" | awk '{print $1}')" = "$(kernel_manifest_value "$key")" ] ||
		fail "public-kernel-hash:$relative"
done
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
base_db=$work/base-installed
debugfs -R "dump -p /lib/apk/db/installed $base_db" "$base" >/dev/null 2>&1 ||
	fail base-apk-database
base_world=$work/base-world
debugfs -R "dump -p /etc/apk/world $base_world" "$base" >/dev/null 2>&1 ||
	fail base-apk-world
passwd_file=$work/passwd
debugfs -R "dump -p /etc/passwd $passwd_file" "$base" >/dev/null 2>&1 ||
	fail base-passwd
user_record=$(awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
' "$passwd_file") || fail regular-user-count
user_uid=$(printf '%s\n' "$user_record" | cut -d: -f3)
user_gid=$(printf '%s\n' "$user_record" | cut -d: -f4)
user_home=$(printf '%s\n' "$user_record" | cut -d: -f6)
case $user_home in /home/*) ;; *) fail invalid-user-home ;; esac
[ "$(grep -c '^P:firmware-meizu-m1892$' "$base_db" || true)" = 0 ] ||
	fail base-already-has-firmware
[ "$(grep -c '^P:rmtfs$' "$base_db" || true)" = 0 ] || fail base-already-has-rmtfs

# Firmware bytes alone cannot make Wi-Fi/cellular appear.  Refuse a base that
# omits the open-source MPSS/WLAN orchestration and its boot runlevel links.
# This cheap gate prevents spending minutes injecting and zeroing an image
# that could only boot to a radio-less desktop.
daily=$tree_root/src/userspace/daily
[ -d "$daily" ] || fail missing-daily-runtime-source
for spec in \
	"/usr/local/sbin/m1892-rmtfs-shadow:$daily/m1892-rmtfs-shadow" \
	"/etc/init.d/m1892-rmtfs-shadow:$daily/m1892-rmtfs-shadow.openrc" \
	"/usr/local/sbin/m1892-radio-bootstrap:$daily/m1892-radio-bootstrap" \
	"/etc/init.d/m1892-radio-bootstrap:$daily/m1892-radio-bootstrap.openrc"; do
	target=${spec%%:*}
	source=${spec#*:}
	[ -f "$source" ] || fail "missing-radio-source:$source"
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$base" >/dev/null 2>&1 ||
		fail "base-missing-radio-runtime:$target"
	# The firmware-free base may predate publication-only comment cleanup. Check
	# executable semantics here, then overlay and byte-verify the canonical
	# current public source below. This permits comment-only base upgrades while
	# still rejecting any changed command, argument, ordering or condition.
	sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$work/current" >"$work/base-semantic"
	sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$source" >"$work/source-semantic"
	cmp -s "$work/base-semantic" "$work/source-semantic" ||
		fail "base-radio-runtime-semantics:$target"
done
for link in /etc/runlevels/boot/m1892-rmtfs-shadow \
	/etc/runlevels/boot/m1892-radio-bootstrap; do
	debugfs -R "stat $link" "$base" >"$work/stat" 2>&1 ||
		fail "base-missing-radio-runlevel:$link"
	grep -q 'Type: symlink' "$work/stat" || fail "base-radio-runlevel-type:$link"
	grep -q "Fast link dest: \"/etc/init.d/${link##*/}\"" "$work/stat" ||
		fail "base-radio-runlevel-target:$link"
done

mkdir -p "$install_root/lib/apk/db" "$install_root/etc/apk"
cp "$base_db" "$install_root/lib/apk/db/installed"
release_metadata_source=$tree_root/src/runtime-inputs/userspace/daily/m1892-release
[ -f "$release_metadata_source" ] || fail missing-release-metadata-source
install -D -m 0644 "$release_metadata_source" "$install_root/etc/m1892-release"
# `apk add` solves the complete world.  An empty staging world would classify
# every package already recorded in the public base as removable and silently
# erase those records. Pin the complete existing name/version set, then prove
# it is byte-for-byte unchanged after adding the firmware, radio and telephony
# bundles.
awk 'BEGIN { RS=""; FS="\n" }
     { name=""; version="" }
     { for (i=1; i<=NF; i++) {
         if ($i ~ /^P:/) name=substr($i,3)
         else if ($i ~ /^V:/) version=substr($i,3)
       }
       if (name!="" && version!="") print name "=" version
     }' "$base_db" | LC_ALL=C sort >"$install_root/etc/apk/world"
cp "$install_root/etc/apk/world" "$work/base-packages.tsv"
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
[ -f "$telephony_archive" ] || fail "missing-runtime-archive:$telephony_archive"
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
telephony_apks=$(find "$telephony_dir" -maxdepth 1 -type f -name '*.apk' | LC_ALL=C sort)
[ -f "$telephony_audio_archive" ] ||
	fail "missing-telephony-audio-runtime:$telephony_audio_archive"
telephony_audio_archive=$(CDPATH='' cd -- "$(dirname -- "$telephony_audio_archive")" && pwd)/$(basename -- "$telephony_audio_archive")
"$script_dir/verify-m1892-telephony-audio-runtime.sh" "$telephony_audio_archive" >/dev/null

# Seed apk with the public base's package database so it can resolve the
# already-present musl/libqrtr/libudev dependencies without a network or a
# second copy of the base filesystem.  Scripts are not executed in staging.
apk --root "$install_root" --arch aarch64 --allow-untrusted \
	--no-network --no-progress add --no-scripts "$firmware_apk" "$rmtfs_apk" "$rmtfs_openrc_apk" \
	"$rmtfs_udev_apk" $telephony_apks >/dev/null

# The Alpine packages provide the public libraries, desktop integration and
# package database entries.  Overlay the two M1892-specific executables built
# from the audited public sources; otherwise a fresh owner image silently
# regresses to the unmodified distribution call-audio behavior.
tar -tzf "$telephony_audio_archive" | awk '
	/^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
	END { exit bad ? 1 : 0 }
' || fail unsafe-telephony-audio-runtime
tar -C "$install_root" -xzf "$telephony_audio_archive"
telephony_audio_root=$work/telephony-audio-expected
mkdir -p "$telephony_audio_root"
tar -C "$telephony_audio_root" -xzf "$telephony_audio_archive"
(cd "$telephony_audio_root" && sha256sum -c MANIFEST.sha256 >/dev/null) ||
	fail telephony-audio-runtime-manifest
for target in /usr/bin/q6voiced \
	/usr/local/libexec/m1892-callaudiod \
	/usr/local/libexec/m1892-telephony-audio.build-info \
	/usr/share/dbus-1/services/org.mobian_project.CallAudio.service; do
	[ -f "$install_root$target" ] || fail "telephony-audio-runtime-file:$target"
done

# Calls and Chatty ship XDG entries that defer to systemd user services.  This
# product intentionally uses OpenRC and has no systemd user manager, so keep
# the standard XDG autostart path active instead of leaving both frontends
# absent during incoming calls and messages.
for desktop in org.gnome.Calls-daemon.desktop sm.puri.Chatty-daemon.desktop; do
	path=$install_root/etc/xdg/autostart/$desktop
	[ -f "$path" ] || fail "missing-telephony-autostart:$desktop"
	sed -i '/^X-GNOME-HiddenUnderSystemd=true$/d' "$path"
	grep -q '^Exec=' "$path" || fail "telephony-autostart-exec:$desktop"
done
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
installed=$install_root/lib/apk/db/installed
[ "$(grep -c '^P:firmware-meizu-m1892$' "$installed")" = 1 ] || fail package-name
firmware_identity=$(awk 'BEGIN { RS=""; FS="\n" }
  $0 ~ /(^|\n)P:firmware-meizu-m1892(\n|$)/ {
    for (i=1; i<=NF; i++) {
      if ($i ~ /^V:/) version=substr($i,3)
      else if ($i ~ /^A:/) arch=substr($i,3)
    }
    print version ":" arch
  }' "$installed")
[ "$firmware_identity" = 20260831-r0:aarch64 ] || fail package-identity
for package in rmtfs rmtfs-openrc rmtfs-udev; do
	identity=$(awk -v wanted="$package" 'BEGIN { RS=""; FS="\n" }
	  { name=""; version="" }
	  { for (i=1; i<=NF; i++) {
	      if ($i ~ /^P:/) name=substr($i,3)
	      else if ($i ~ /^V:/) version=substr($i,3)
	    }
	    if (name==wanted) print version
	  }' "$installed")
	[ "$identity" = 1.3-r0 ] || fail "runtime-package-identity:$package"
done
while IFS='=' read -r package expected_version; do
	identity=$(awk -v wanted="$package" 'BEGIN { RS=""; FS="\n" }
	  { name=""; version="" }
	  { for (i=1; i<=NF; i++) {
	      if ($i ~ /^P:/) name=substr($i,3)
	      else if ($i ~ /^V:/) version=substr($i,3)
	    }
	    if (name==wanted) print version
	  }' "$installed")
	[ "$identity" = "$expected_version" ] ||
		fail "telephony-package-identity:$package:$identity"
done <"$telephony_dir/PACKAGES"
{
	printf '%s\n' firmware-meizu-m1892=20260831-r0 \
		rmtfs=1.3-r0 rmtfs-openrc=1.3-r0 rmtfs-udev=1.3-r0
	cat "$telephony_dir/PACKAGES"
} | LC_ALL=C sort -u >"$work/injected-packages.tsv"
awk 'BEGIN { RS=""; FS="\n" }
     { name=""; version="" }
     { for (i=1; i<=NF; i++) {
         if ($i ~ /^P:/) name=substr($i,3)
         else if ($i ~ /^V:/) version=substr($i,3)
       }
       if (name!="" && version!="") print name "=" version
     }' "$installed" | LC_ALL=C sort >"$work/all-installed-packages.tsv"
comm -23 "$work/all-installed-packages.tsv" "$work/injected-packages.tsv" \
	>"$work/retained-packages.tsv"
cmp -s "$work/base-packages.tsv" "$work/retained-packages.tsv" ||
	fail existing-package-database-changed
usr_file_count=$(find "$install_root/usr" -type f | wc -l)
[ "$usr_file_count" -gt 151 ] || fail package-file-count
[ -L "$install_root/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn" ] ||
	fail package-wlanmdsp-link
[ "$(readlink "$install_root/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn")" = \
  ../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn ] || fail package-wlanmdsp-link-target
[ -f "$install_root/etc/conf.d/rmtfs" ] || fail rmtfs-conf-payload
[ -f "$install_root/etc/init.d/rmtfs" ] || fail rmtfs-openrc-payload
[ ! -e "$install_root/usr/share/qcom/sdm845/Meizu/m1892/sensors/registry" ] ||
	fail factory-calibration-in-package

check_hash()
{
	expected=$1 path=$2
	[ "$(sha256sum "$install_root$path" | awk '{print $1}')" = "$expected" ] ||
		fail "firmware-hash:$path"
}
check_hash da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6 \
	/usr/lib/firmware/qcom/a630_gmu.bin
check_hash 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c \
	/usr/lib/firmware/qcom/a630_sqe.fw
check_hash c97cd5de29a3a4b5367173295479141e84da37a4a55162a9b6959ea601ff6b9a \
	/usr/lib/firmware/qcom/sdm845/m1892/a630_zap.mbn
check_hash 13633048cd98816d8f2c1cbe8dcd00193f24953d7e52208a51cb51f96617e9b4 \
	/usr/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin
check_hash 92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2 \
	/usr/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn
check_hash 18cc38fff25a6a56bc163f1874184da93d90882dc047c9f0c534ed9888c543b3 \
	/usr/lib/firmware/qca/m1892/crnv21.bin
check_hash 96a20c1c7d330c4abb79ee52045489c51e6744a86772ccdb50994494d5471ef4 \
	/usr/lib/firmware/qcom/m1892/dw_172hz.bin

combined_db=$work/installed
combined_world=$work/world
batch=$work/debugfs.batch
marker=$work/m1892-fresh-image
if [ -n "$root_authorized_keys" ]; then
	privacy='absent-machine-id,no-host-keys,owner-root-public-key,generic-cellular-autoconfig-only,no-user-network-profiles'
else
	privacy='absent-machine-id,no-host-keys,no-user-keys,generic-cellular-autoconfig-only,no-user-network-profiles'
fi
cp "$installed" "$combined_db"
[ "$(grep -c '^P:firmware-meizu-m1892$' "$combined_db")" = 1 ] ||
	fail combined-apk-database
[ "$(grep -c '^P:rmtfs$' "$combined_db")" = 1 ] || fail combined-rmtfs-database
[ "$(grep -c '^P:rmtfs-openrc$' "$combined_db")" = 1 ] || fail combined-rmtfs-openrc-database
[ "$(grep -c '^P:rmtfs-udev$' "$combined_db")" = 1 ] || fail combined-rmtfs-udev-database
# The owner-local injector adds the radio runtime after the public base was
# built.  Keep those packages in apk's explicit world as well as in the
# installed database; otherwise a later unrelated `apk add` is allowed to
# garbage-collect the modem runtime and silently break Wi-Fi/cellular.
{
	cat "$base_world"
	printf '%s\n' rmtfs rmtfs-openrc rmtfs-udev
	cut -d= -f1 "$telephony_dir/PACKAGES"
} | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u >"$combined_world"
for package in rmtfs rmtfs-openrc rmtfs-udev calls \
	chatty purple-mm-sms callaudiod q6voiced q6voiced-openrc; do
	[ "$(grep -cx "$package" "$combined_world")" = 1 ] ||
		fail "combined-world:$package"
done
cat >"$marker" <<EOF
release=m1892-mainline-2026.09-developer-preview.17-owner-firmware
firmware=owner-generated-flyme-8.1.9.0A-plus-linux-firmware-20260221
radio-runtime=alpine-rmtfs-1.3-r0-plus-root-managed-bootstrap
telephony=m1892-81voltd-openimsd-gnome-calls-chatty-q6voiced-voicemmode1-sms-over-ims
speaker-modules=source-built-public-kernel-bundle
input-method=stevia-standard-wayland-seat-fcitx-autostart-disabled
calibration=absent-first-boot-imports-this-phone-persist-ro-noload
privacy=$privacy
EOF

if [ "$preseeded" = 1 ]; then
	[ -f "$output" ] || fail missing-preseeded-output
	[ "$(stat -c %s "$output")" = "$expected_size" ] || fail preseeded-size
	[ "$(sha256sum "$output" | awk '{print $1}')" = "$expected_base" ] ||
		fail preseeded-hash
elif ! cp --reflink=auto --sparse=always "$base" "$output" 2>/dev/null; then
	# Rootless/chroot builders may reject reflink ioctls. Preserve holes in the
	# fallback as well; a plain cp needlessly allocates the full 8 GiB image.
	cp --sparse=always "$base" "$output"
fi
printf 'rm /lib/apk/db/installed\nwrite %s /lib/apk/db/installed\n' \
	"$combined_db" >"$batch"
printf 'rm /etc/apk/world\nwrite %s /etc/apk/world\n' "$combined_world" >>"$batch"
cat >>"$batch" <<'EOF'
rm /usr/lib/m1892/speaker/snd-soc-cs35l41-lib-r442.ko
rm /usr/lib/m1892/speaker/snd-soc-cs35l41-r442.ko
rm /usr/lib/m1892/speaker/snd-soc-sdm845-r437.ko
EOF
# The privacy-clean public base intentionally has no vendor firmware subtree.
# Create every APK directory in parent-first order before writing payload files;
# debugfs otherwise keeps processing after a missing-parent error and still exits
# successfully for the batch as a whole.
find "$install_root/usr" -type d | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	printf 'mkdir %s\n' "$target"
done >>"$batch"
find "$install_root/usr" -type f | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	printf 'rm %s\nwrite %s %s\n' "$target" "$source" "$target"
done >>"$batch"
# APK payloads may contain semantic aliases in addition to regular files. If
# the image writer only iterates regular files, wlanmdsp is present in the APK
# database but absent at the path requested by tqftpserv.
find "$install_root/usr" -type l | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	link_target=$(readlink "$source")
	# debugfs syntax is `symlink <new-path> <link-target>`.  Reversing these
	# arguments tries to resolve the relative link target as a filesystem path
	# and silently leaves the required Qualcomm alias absent.
	printf 'rm %s\nsymlink %s %s\n' "$target" "$target" "$link_target"
done >>"$batch"
# The pinned OpenIMSd/libqmi runtime deliberately lives in an isolated /opt
# prefix so it cannot replace the distribution libqmi used by ModemManager.
find "$install_root/opt" -type d | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	printf 'mkdir %s\n' "$target"
done >>"$batch"
find "$install_root/opt" -type f | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	mode=$(stat -c %a "$source")
	printf 'rm %s\nwrite %s %s\nset_inode_field %s mode 0100%s\n' \
		"$target" "$source" "$target" "$target" "$mode"
done >>"$batch"
find "$install_root/opt" -type l | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	link_target=$(readlink "$source")
	printf 'rm %s\nsymlink %s %s\n' "$target" "$target" "$link_target"
done >>"$batch"
# Copy package-owned service and session integration.  `/etc/apk` is handled
# separately by the combined installed/world contracts above.
find "$install_root/etc" -type d ! -path "$install_root/etc/apk*" | LC_ALL=C sort |
while IFS= read -r source; do
	target=${source#"$install_root"}
	printf 'mkdir %s\n' "$target"
done >>"$batch"
find "$install_root/etc" -type f ! -path "$install_root/etc/apk/*" | LC_ALL=C sort |
while IFS= read -r source; do
	target=${source#"$install_root"}
	mode=$(stat -c %a "$source")
	printf 'rm %s\nwrite %s %s\nset_inode_field %s mode 0100%s\n' \
		"$target" "$source" "$target" "$target" "$mode"
done >>"$batch"

# Product runtime configuration must come only from this public source tree.
# Never fall back to a sibling checkout: that would make the owner
# image depend on files that a fresh GitHub clone cannot see.
resolve_runtime_source()
{
	relative=$1
	source=$tree_root/src/runtime-inputs/$relative
	[ -f "$source" ] || fail "missing-runtime-source:$relative"
	printf '%s\n' "$source"
}
ucm_top=$(resolve_runtime_source m1892-userspace/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf)
ucm_hifi=$(resolve_runtime_source m1892-userspace/ucm2/Meizu/m1892/HiFi.conf)
ucm_voice=$(resolve_runtime_source m1892-userspace/ucm2/Meizu/m1892/VoiceCall.conf)
q6voiced_conf=$(resolve_runtime_source m1892-userspace/q6voiced/q6voiced.conf)
q6voiced_openrc=$(resolve_runtime_source m1892-userspace/q6voiced/q6voiced.openrc)
speaker_openrc=$(resolve_runtime_source m1892-userspace/openrc/m1892-speaker)
telephony_policy=$(resolve_runtime_source userspace/telephony/48-m1892-telephony.rules)
bluetooth_openrc=$(resolve_runtime_source userspace/bluetooth/bluetooth.openrc)
bluetooth_identity=$(resolve_runtime_source userspace/bluetooth/m1892-bluetooth-identity)
bluetooth_selftest=$(resolve_runtime_source userspace/bluetooth/m1892-bluetooth-selftest)
power_runtime=$(resolve_runtime_source userspace/daily/m1892-power)
power_openrc=$(resolve_runtime_source userspace/daily/m1892-power.openrc)
daily_health=$(resolve_runtime_source userspace/daily/m1892-daily-health)
docker_selftest=$(resolve_runtime_source userspace/daily/m1892-docker-selftest)
rmtfs_shadow=$(resolve_runtime_source userspace/daily/m1892-rmtfs-shadow)
rmtfs_shadow_openrc=$(resolve_runtime_source userspace/daily/m1892-rmtfs-shadow.openrc)
radio_bootstrap=$(resolve_runtime_source userspace/daily/m1892-radio-bootstrap)
radio_bootstrap_openrc=$(resolve_runtime_source userspace/daily/m1892-radio-bootstrap.openrc)
cat >>"$batch" <<EOF
mkdir /usr/share/alsa/ucm2/Meizu/m1892
rm /usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf
write $ucm_top /usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf
set_inode_field /usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf mode 0100644
rm /usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf
write $ucm_hifi /usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf
set_inode_field /usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf mode 0100644
rm /usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf
write $ucm_voice /usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf
set_inode_field /usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf mode 0100644
mkdir /usr/share/q6voiced
rm /usr/share/q6voiced/q6voiced.conf
write $q6voiced_conf /usr/share/q6voiced/q6voiced.conf
set_inode_field /usr/share/q6voiced/q6voiced.conf mode 0100644
rm /etc/init.d/q6voiced
write $q6voiced_openrc /etc/init.d/q6voiced
set_inode_field /etc/init.d/q6voiced mode 0100755
rm /etc/init.d/m1892-speaker
write $speaker_openrc /etc/init.d/m1892-speaker
set_inode_field /etc/init.d/m1892-speaker mode 0100755
rm /etc/init.d/bluetooth
write $bluetooth_openrc /etc/init.d/bluetooth
set_inode_field /etc/init.d/bluetooth mode 0100755
rm /usr/local/sbin/m1892-bluetooth-identity
write $bluetooth_identity /usr/local/sbin/m1892-bluetooth-identity
set_inode_field /usr/local/sbin/m1892-bluetooth-identity mode 0100755
rm /usr/local/sbin/m1892-bluetooth-selftest
write $bluetooth_selftest /usr/local/sbin/m1892-bluetooth-selftest
set_inode_field /usr/local/sbin/m1892-bluetooth-selftest mode 0100755
rm /usr/local/sbin/m1892-power
write $power_runtime /usr/local/sbin/m1892-power
set_inode_field /usr/local/sbin/m1892-power mode 0100755
rm /etc/init.d/m1892-power
write $power_openrc /etc/init.d/m1892-power
set_inode_field /etc/init.d/m1892-power mode 0100755
rm /usr/local/sbin/m1892-daily-health
write $daily_health /usr/local/sbin/m1892-daily-health
set_inode_field /usr/local/sbin/m1892-daily-health mode 0100755
rm /usr/local/sbin/m1892-docker-selftest
write $docker_selftest /usr/local/sbin/m1892-docker-selftest
set_inode_field /usr/local/sbin/m1892-docker-selftest mode 0100755
rm /usr/local/sbin/m1892-rmtfs-shadow
write $rmtfs_shadow /usr/local/sbin/m1892-rmtfs-shadow
set_inode_field /usr/local/sbin/m1892-rmtfs-shadow mode 0100755
rm /etc/init.d/m1892-rmtfs-shadow
write $rmtfs_shadow_openrc /etc/init.d/m1892-rmtfs-shadow
set_inode_field /etc/init.d/m1892-rmtfs-shadow mode 0100755
rm /usr/local/sbin/m1892-radio-bootstrap
write $radio_bootstrap /usr/local/sbin/m1892-radio-bootstrap
set_inode_field /usr/local/sbin/m1892-radio-bootstrap mode 0100755
rm /etc/init.d/m1892-radio-bootstrap
write $radio_bootstrap_openrc /etc/init.d/m1892-radio-bootstrap
set_inode_field /etc/init.d/m1892-radio-bootstrap mode 0100755
mkdir /etc/polkit-1/rules.d
rm /etc/polkit-1/rules.d/48-m1892-telephony.rules
write $telephony_policy /etc/polkit-1/rules.d/48-m1892-telephony.rules
set_inode_field /etc/polkit-1/rules.d/48-m1892-telephony.rules mode 0100644
rm /etc/runlevels/default/q6voiced
symlink /etc/runlevels/default/q6voiced /etc/init.d/q6voiced
rm /etc/runlevels/default/81voltd
symlink /etc/runlevels/default/81voltd /etc/init.d/81voltd
rm /etc/runlevels/default/m1892-qcom-imsd
symlink /etc/runlevels/default/m1892-qcom-imsd /etc/init.d/m1892-qcom-imsd
EOF
for target in /etc/conf.d/rmtfs /etc/init.d/rmtfs /etc/init.d/q6voiced \
	/etc/init.d/81voltd /etc/init.d/m1892-qcom-imsd; do
	source=$install_root$target
	[ -f "$source" ] || fail "missing-service-payload:$target"
done
cat >>"$batch" <<EOF
mkdir $user_home/.config
mkdir $user_home/.config/autostart
rm $user_home/.config/autostart/org.fcitx.Fcitx5.desktop
write $fcitx_override $user_home/.config/autostart/org.fcitx.Fcitx5.desktop
set_inode_field $user_home/.config/autostart/org.fcitx.Fcitx5.desktop mode 0100644
set_inode_field $user_home/.config/autostart/org.fcitx.Fcitx5.desktop uid $user_uid
set_inode_field $user_home/.config/autostart/org.fcitx.Fcitx5.desktop gid $user_gid
mkdir /etc/NetworkManager/system-connections
rm /etc/NetworkManager/system-connections/m1892-cellular.nmconnection
write $cellular_profile /etc/NetworkManager/system-connections/m1892-cellular.nmconnection
set_inode_field /etc/NetworkManager/system-connections mode 040700
set_inode_field /etc/NetworkManager/system-connections uid 0
set_inode_field /etc/NetworkManager/system-connections gid 0
set_inode_field /etc/NetworkManager/system-connections/m1892-cellular.nmconnection mode 0100600
set_inode_field /etc/NetworkManager/system-connections/m1892-cellular.nmconnection uid 0
set_inode_field /etc/NetworkManager/system-connections/m1892-cellular.nmconnection gid 0
rm /etc/m1892-fresh-image
write $marker /etc/m1892-fresh-image
EOF
if [ -n "$root_authorized_keys" ]; then
	cat >>"$batch" <<EOF
mkdir /root/.ssh
rm /root/.ssh/authorized_keys
write $root_authorized_keys /root/.ssh/authorized_keys
set_inode_field /root/.ssh mode 040700
set_inode_field /root/.ssh uid 0
set_inode_field /root/.ssh gid 0
set_inode_field /root/.ssh/authorized_keys mode 0100600
set_inode_field /root/.ssh/authorized_keys uid 0
set_inode_field /root/.ssh/authorized_keys gid 0
EOF
fi
debugfs -w -f "$batch" "$output" >/dev/null 2>"$work/debugfs.log" || {
	sed -n '1,120p' "$work/debugfs.log" >&2
	fail debugfs-update
}
# Do not trust debugfs' batch exit status.  Read every payload back and compare
# it before finalizing the filesystem so a missing directory/file cannot produce
# a superficially successful release image.
checked=0
find "$install_root/usr" -type f | LC_ALL=C sort | while IFS= read -r source; do
	target=${source#"$install_root"}
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$output" >/dev/null 2>&1 ||
		fail "missing:$target"
	[ -f "$work/current" ] || fail "missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$source" | awk '{print $1}')" ] || fail "content:$target"
	checked=$((checked + 1))
	printf '%s\n' "$checked" >"$work/checked"
done
[ "$(cat "$work/checked")" = "$usr_file_count" ] || fail compared-file-count
wlanmdsp_link=/usr/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn
debugfs -R "stat $wlanmdsp_link" "$output" >"$work/wlanmdsp-stat" 2>&1 ||
	fail missing-wlanmdsp-link
grep -q 'Type: symlink' "$work/wlanmdsp-stat" || fail wlanmdsp-link-type
grep -Fq 'Fast link dest: "../../../ath10k/WCN3990/hw1.0/wlanmdsp.mbn"' \
	"$work/wlanmdsp-stat" || fail wlanmdsp-link-target
for target in /etc/conf.d/rmtfs /etc/init.d/rmtfs; do
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$output" >/dev/null 2>&1 ||
		fail "missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$install_root$target" | awk '{print $1}')" ] || fail "content:$target"
done
[ "$(debugfs -R 'cat /usr/share/q6voiced/q6voiced.conf' "$output" 2>/dev/null)" = \
	"$(cat "$q6voiced_conf")" ] || fail q6voiced-config
[ "$(debugfs -R 'cat /etc/init.d/q6voiced' "$output" 2>/dev/null)" = \
	"$(cat "$q6voiced_openrc")" ] || fail q6voiced-openrc
for target in /usr/bin/q6voiced \
	/usr/local/libexec/m1892-callaudiod \
	/usr/local/libexec/m1892-telephony-audio.build-info \
	/usr/share/dbus-1/services/org.mobian_project.CallAudio.service; do
	rm -f "$work/current"
	debugfs -R "dump -p $target $work/current" "$output" >/dev/null 2>&1 ||
		fail "missing-telephony-audio-runtime:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$telephony_audio_root$target" | awk '{print $1}')" ] ||
		fail "content-telephony-audio-runtime:$target"
done
while read -r expected relative; do
	case $relative in etc/*|opt/*|usr/*) ;; *) fail "telephony-audio-manifest-path:$relative" ;; esac
	rm -f "$work/current"
	debugfs -R "dump -p /$relative $work/current" "$output" >/dev/null 2>&1 ||
		fail "missing-telephony-audio-manifest-file:/$relative"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = "$expected" ] ||
		fail "content-telephony-audio-manifest-file:/$relative"
done <"$telephony_audio_root/MANIFEST.sha256"
debugfs -R 'stat /opt/m1892-openimsd/lib/libqmi-glib.so.5' "$output" \
	>"$work/qmi-soname-stat" 2>&1 || fail qmi-soname-link
grep -q 'Type: symlink' "$work/qmi-soname-stat" || fail qmi-soname-link-type
[ "$(debugfs -R 'cat /etc/init.d/m1892-speaker' "$output" 2>/dev/null)" = \
	"$(cat "$speaker_openrc")" ] || fail speaker-openrc
[ "$(debugfs -R 'cat /etc/init.d/bluetooth' "$output" 2>/dev/null)" = \
	"$(cat "$bluetooth_openrc")" ] || fail bluetooth-openrc
[ "$(debugfs -R 'cat /usr/local/sbin/m1892-bluetooth-identity' "$output" 2>/dev/null)" = \
	"$(cat "$bluetooth_identity")" ] || fail bluetooth-identity
[ "$(debugfs -R 'cat /usr/local/sbin/m1892-bluetooth-selftest' "$output" 2>/dev/null)" = \
	"$(cat "$bluetooth_selftest")" ] || fail bluetooth-selftest
[ "$(debugfs -R 'cat /usr/local/sbin/m1892-power' "$output" 2>/dev/null)" = \
	"$(cat "$power_runtime")" ] || fail power-runtime
[ "$(debugfs -R 'cat /etc/init.d/m1892-power' "$output" 2>/dev/null)" = \
	"$(cat "$power_openrc")" ] || fail power-openrc
[ "$(debugfs -R 'cat /usr/local/sbin/m1892-daily-health' "$output" 2>/dev/null)" = \
	"$(cat "$daily_health")" ] || fail daily-health
[ "$(debugfs -R 'cat /etc/polkit-1/rules.d/48-m1892-telephony.rules' "$output" 2>/dev/null)" = \
	"$(cat "$telephony_policy")" ] || fail telephony-polkit
for desktop in org.gnome.Calls-daemon.desktop sm.puri.Chatty-daemon.desktop; do
	rm -f "$work/current"
	debugfs -R "dump -p /etc/xdg/autostart/$desktop $work/current" "$output" \
		>/dev/null 2>&1 || fail "telephony-autostart:$desktop"
	grep -q '^Exec=' "$work/current" || fail "telephony-autostart-exec:$desktop"
	! grep -qx 'X-GNOME-HiddenUnderSystemd=true' "$work/current" ||
		fail "telephony-autostart-hidden:$desktop"
done
debugfs -R 'stat /etc/init.d/q6voiced' "$output" 2>/dev/null | \
	grep -Eq 'Mode:.*0755' || fail q6voiced-openrc-mode
debugfs -R 'stat /etc/init.d/m1892-speaker' "$output" 2>/dev/null | \
	grep -Eq 'Mode:.*0755' || fail speaker-openrc-mode
for target in /etc/init.d/bluetooth /usr/local/sbin/m1892-bluetooth-identity \
	/usr/local/sbin/m1892-bluetooth-selftest /usr/local/sbin/m1892-power \
	/etc/init.d/m1892-power /usr/local/sbin/m1892-daily-health; do
	debugfs -R "stat $target" "$output" 2>/dev/null |
		grep -Eq 'Mode:.*0755' || fail "bluetooth-mode:$target"
done
[ "$(debugfs -R 'cat /usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf' "$output" 2>/dev/null)" = \
	"$(cat "$ucm_hifi")" ] || fail ucm-hifi-config
[ "$(debugfs -R 'cat /usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf' "$output" 2>/dev/null)" = \
	"$(cat "$ucm_voice")" ] || fail ucm-voice-config
debugfs -R 'stat /etc/runlevels/default/q6voiced' "$output" >"$work/q6voiced-runlevel" 2>&1 ||
	fail q6voiced-runlevel
grep -q 'Type: symlink' "$work/q6voiced-runlevel" || fail q6voiced-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/q6voiced"' "$work/q6voiced-runlevel" ||
	fail q6voiced-runlevel-target
debugfs -R 'stat /etc/runlevels/default/81voltd' "$output" >"$work/81voltd-runlevel" 2>&1 ||
	fail 81voltd-runlevel
grep -q 'Type: symlink' "$work/81voltd-runlevel" || fail 81voltd-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/81voltd"' "$work/81voltd-runlevel" ||
	fail 81voltd-runlevel-target
debugfs -R 'stat /etc/runlevels/default/m1892-qcom-imsd' "$output" \
	>"$work/qcom-imsd-runlevel" 2>&1 || fail qcom-imsd-runlevel
grep -q 'Type: symlink' "$work/qcom-imsd-runlevel" || fail qcom-imsd-runlevel-type
grep -q 'Fast link dest: "/etc/init.d/m1892-qcom-imsd"' "$work/qcom-imsd-runlevel" ||
	fail qcom-imsd-runlevel-target
[ "$(debugfs -R 'cat /etc/apk/world' "$output" 2>/dev/null | grep -Ec '^(rmtfs|rmtfs-openrc|rmtfs-udev)$')" = 3 ] ||
	fail output-radio-world
[ "$(debugfs -R 'cat /etc/apk/world' "$output" 2>/dev/null | grep -Ec '^(calls|chatty|q6voiced|q6voiced-openrc)$')" = 4 ] ||
	fail output-telephony-world
rm -f "$work/current"
debugfs -R "dump -p $user_home/.config/autostart/org.fcitx.Fcitx5.desktop $work/current" \
	"$output" >/dev/null 2>&1 || fail missing-fcitx-autostart-override
[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
  "$(sha256sum "$fcitx_override" | awk '{print $1}')" ] ||
	fail content-fcitx-autostart-override
rm -f "$work/current"
debugfs -R "dump -p /etc/NetworkManager/system-connections/m1892-cellular.nmconnection $work/current" \
	"$output" >/dev/null 2>&1 || fail missing-generic-cellular-profile-output
cmp -s "$cellular_profile" "$work/current" || fail content-generic-cellular-profile-output
debugfs -R 'stat /etc/NetworkManager/system-connections' "$output" \
	>"$work/nm-system-connections-stat" 2>&1 || fail nm-system-connections-stat
debugfs -R 'stat /etc/NetworkManager/system-connections/m1892-cellular.nmconnection' \
	"$output" >"$work/cellular-profile-stat" 2>&1 || fail cellular-profile-stat
grep -Eq 'Mode:[[:space:]]+0700' "$work/nm-system-connections-stat" ||
	fail nm-system-connections-mode
grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
	"$work/nm-system-connections-stat" || fail nm-system-connections-owner
grep -Eq 'Mode:[[:space:]]+0600' "$work/cellular-profile-stat" ||
	fail generic-cellular-profile-mode
grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
	"$work/cellular-profile-stat" || fail generic-cellular-profile-owner
if [ -n "$root_authorized_keys" ]; then
	rm -f "$work/current"
	debugfs -R "dump -p /root/.ssh/authorized_keys $work/current" "$output" \
		>/dev/null 2>&1 || fail missing-root-authorized-keys-output
	cmp -s "$root_authorized_keys" "$work/current" ||
		fail content-root-authorized-keys-output
	debugfs -R 'stat /root/.ssh' "$output" >"$work/root-ssh-stat" 2>&1 ||
		fail root-ssh-stat
	debugfs -R 'stat /root/.ssh/authorized_keys' "$output" \
		>"$work/root-authorized-keys-stat" 2>&1 || fail root-authorized-keys-stat
	grep -Eq 'Mode:[[:space:]]+0700' "$work/root-ssh-stat" || fail root-ssh-mode
	grep -Eq 'Mode:[[:space:]]+0600' "$work/root-authorized-keys-stat" ||
		fail root-authorized-keys-mode
	grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0([[:space:]]|$)' \
		"$work/root-authorized-keys-stat" || fail root-authorized-keys-owner
fi
fsck_repair "$output"
# This phone is repeatedly hard-reset during development. Three independent
# outages corrupted only ext4's scalable orphan-file checksum and then blocked
# the root mount. The feature is a throughput optimization, not a consistency
# requirement; use the traditional orphan list for the public daily image.
tune2fs -O ^orphan_file "$output" >/dev/null
fsck_repair "$output"
zerofree "$output"
e2fsck -fn "$output" >/dev/null || fail final-filesystem
! tune2fs -l "$output" | grep '^Filesystem features:.*\borphan_file\b' >/dev/null ||
	fail orphan-file-feature-remains
echo "output=$output"
sha256sum "$output"
echo M1892_LOCAL_FIRMWARE_IMAGE_PASS
