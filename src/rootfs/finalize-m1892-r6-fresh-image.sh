#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
image=${1:-}
overlay_archive=${2:-}
root_uuid=3982b874-0ec0-57c4-a83b-37965b6be709
[ -z "${E2FSPROGS_DIR:-}" ] || PATH=$E2FSPROGS_DIR:$PATH
export PATH
fail() { echo "M1892_FRESH_FINALIZE_FAIL: $*" >&2; exit 1; }
fsck_repair()
{
	status=0
	e2fsck -fy "$1" >/dev/null || status=$?
	case $status in
		0|1) ;;
		*) fail "filesystem-repair:$status" ;;
	esac
}

test -f "$image" || fail missing-image
test -f "$overlay_archive" || fail missing-userspace-overlay
test "$(id -u)" = 0 || fail root-required
test -z "$(losetup -j "$image")" || fail image-already-mounted
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 { print $2 }')
[ "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -1)" = 1.47.4 ] ||
	fail "e2fsprogs-too-old:$e2fs_version"

tmp=$(mktemp -d)
mountpoint=$tmp/root
bundle_root=$tmp/bundle
mounted=no
cleanup()
{
	if test "$mounted" = yes; then
		umount "$mountpoint" || true
	fi
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

fsck_repair "$image"
tune2fs -U "$root_uuid" "$image"
install -d "$mountpoint" "$bundle_root"
mount -o rw,loop "$image" "$mountpoint"
mounted=yes

tar -C "$bundle_root" -xzf "$overlay_archive"
bundle=$(find "$bundle_root" -mindepth 1 -maxdepth 1 -type d | head -1)
test -n "$bundle" || fail overlay-layout
(cd "$bundle" && sha256sum -c BUNDLE_MANIFEST.sha256 >/dev/null) || fail overlay-integrity
(cd "$bundle/payload" && tar -cf - .) | (cd "$mountpoint" && tar -xf -)
# The packaged Phoc ELF belongs to the verified userspace bundle.  The rootfs
# overlay may contain a convenience copy whose drvfs metadata is
# not authoritative; never let that copy replace the bundle payload.
(cd "$script_dir/fresh-overlay" && tar --exclude='./usr/bin/phoc' -cf - .) |
	(cd "$mountpoint" && tar -xf -)

fresh_metadata=$script_dir/fresh-overlay-metadata.tsv
test -r "$fresh_metadata" || fail missing-fresh-overlay-metadata
# Normalize every directory introduced by the overlay as well. The later
# NetworkManager block deliberately tightens its credential directory to 0700.
(cd "$script_dir/fresh-overlay" && find . -type d -print) |
while IFS= read -r relative; do
	chown 0:0 "$mountpoint/$relative"
	chmod 0755 "$mountpoint/$relative"
done
tab=$(printf '\t')
while IFS="$tab" read -r target mode; do
	case $target in ''|'#'*) continue ;; esac
	test -f "$mountpoint$target" || fail "fresh-overlay-target:$target"
	chown 0:0 "$mountpoint$target"
	chmod "$mode" "$mountpoint$target"
done <"$fresh_metadata"

# SOURCE_FILES.tsv is the root-owned runtime installation contract.  Host
# filesystems such as WSL drvfs can report every source as uid 1000/mode 0777;
# normalize every installed target explicitly instead of trusting tar metadata.
runtime_contract=
for candidate in \
	"$script_dir/../userspace-overlay/SOURCE_FILES.tsv" \
	"$script_dir/../runtime/SOURCE_FILES.tsv"; do
	test -r "$candidate" || continue
	runtime_contract=$candidate
	break
done
test -n "$runtime_contract" || fail missing-runtime-contract
while IFS="$tab" read -r source target mode component; do
	case $source in ''|'#'*) continue ;; esac
	test -f "$mountpoint$target" || fail "runtime-contract-target:$target"
	chown 0:0 "$mountpoint$target"
	chmod "$mode" "$mountpoint$target"
done <"$runtime_contract"

# pmbootstrap owns account creation.  Resolve the one regular local user from
# passwd instead of coupling hardware integration to a username, UID or home
# path.  Public builders may therefore use `pmbootstrap config user ...`.
user_record=$(awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
' "$mountpoint/etc/passwd") || fail regular-user-count
user_name=$(printf '%s\n' "$user_record" | cut -d: -f1)
user_uid=$(printf '%s\n' "$user_record" | cut -d: -f3)
user_gid=$(printf '%s\n' "$user_record" | cut -d: -f4)
user_home=$(printf '%s\n' "$user_record" | cut -d: -f6)
case $user_name in
	''|*[!a-zA-Z0-9_-]*) fail invalid-user-name ;;
esac
case $user_home in
	/home/*) ;;
	*) fail invalid-user-home ;;
esac
test -d "$mountpoint$user_home" || fail user-home-absent

# Docker's root-owned socket is intentionally exposed through the standard
# distribution `docker` group. Resolve the pmbootstrap-created account above;
# never couple this permission to a fixed username or UID.
group_new=$tmp/group
awk -F: -v OFS=: -v user="$user_name" '
	$1 == "docker" {
		found=1
		n=split($4, members, ",")
		present=0
		for (i=1; i<=n; i++) if (members[i] == user) present=1
		if (!present) $4=($4 == "" ? user : $4 "," user)
	}
	{ print }
	END { if (!found) exit 1 }
' "$mountpoint/etc/group" >"$group_new" || fail docker-group-absent
cat "$group_new" >"$mountpoint/etc/group"
awk -F: -v user="$user_name" '$1=="docker" {
	n=split($4, members, ","); for (i=1; i<=n; i++) if (members[i]==user) ok=1
} END { exit ok ? 0 : 1 }' "$mountpoint/etc/group" || fail docker-group-membership

# The desktop autologin target follows the account produced by pmbootstrap.
sed -i "/^\[initial_session\]/,/^$/ s/^user = .*/user = \"$user_name\"/" \
	"$mountpoint/etc/phrog/greetd-config.toml"
grep -A2 '^\[initial_session\]' "$mountpoint/etc/phrog/greetd-config.toml" |
	grep -qx "user = \"$user_name\"" || fail greetd-user

# Earlier integration inputs may record a source installation UUID in runtime
# helpers.  The initramfs already authenticates the
# handset, GPT, UFS identity, exact partition and fresh filesystem UUID before
# switch_root.  Runtime services retain their hardware, ext4 and UFS checks,
# but must not turn one source-image UUID into a product whitelist.
for helper in \
	m1892-daily-health m1892-cellular-prepare m1892-power m1892-sensors \
	m1892-ufs-policy m1892-suspend m1892-safe-restart; do
	file=$mountpoint/usr/local/sbin/$helper
	test -f "$file" || fail "missing-helper:$helper"
	sed -i \
		-e '/^root_uuid=/d' \
		-e '/findmnt -n -o UUID \//d' \
		"$file"
done
# `m1892-safe-fastboot` prints the installed UUID as diagnostic evidence, so
# retain its `root_uuid` value but remove the value as an authorization gate.
# Deleting both lines mechanically would leave the status path referencing an
# unset variable under `set -u`.
safe_fastboot=$mountpoint/usr/local/sbin/m1892-safe-fastboot
test -f "$safe_fastboot" || fail missing-helper:m1892-safe-fastboot
sed -i '/findmnt -n -o UUID \/.*root_uuid/d' "$safe_fastboot"
if grep -Rl 'findmnt -n -o UUID /' "$mountpoint/usr/local/sbin"/m1892-* |
	grep -q .; then
	fail runtime-uuid-whitelist-remains
fi

sed -i "s#^UUID=[^ ]* / ext4 #UUID=$root_uuid / ext4 #" "$mountpoint/etc/fstab"
grep -qx "UUID=$root_uuid / ext4 defaults 0 0" "$mountpoint/etc/fstab" || fail fstab

# A cloned image must not reuse build-host or SSH identity.  Alpine's OpenRC
# dbus service runs `dbus-uuidgen --ensure=/etc/machine-id` at start.  That
# command creates an absent file, but deliberately rejects an existing empty
# file.  Remove both aliases so first boot can generate one valid identity.
rm -f "$mountpoint/etc/machine-id" "$mountpoint/var/lib/dbus/machine-id"
rm -f "$mountpoint"/etc/ssh/ssh_host_* 2>/dev/null || true
# Preserve only the distribution-owned, operator-neutral cellular profile.
# NetworkManager obtains APN details from mobile-broadband-provider-info at
# runtime; the image must never retain owner Wi-Fi, APN or subscriber secrets.
cellular_profile=$mountpoint/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
test -f "$cellular_profile" || fail missing-generic-cellular-profile
find "$mountpoint/etc/NetworkManager/system-connections" -mindepth 1 -type f \
	! -name m1892-cellular.nmconnection -delete 2>/dev/null || true
chown 0:0 "$mountpoint/etc/NetworkManager/system-connections" "$cellular_profile"
chmod 0700 "$mountpoint/etc/NetworkManager/system-connections"
chmod 0600 "$cellular_profile"
find "$mountpoint/home" "$mountpoint/root" -type f \( -name authorized_keys -o -name known_hosts -o -name 'id_*' \) -delete 2>/dev/null || true

# Direct graphical autologin is intentional during development; neither local
# account accepts a password. SSH access is provisioned explicitly after flash.
sed -i "s#^root:[^:]*:#root:!:#; s#^${user_name}:[^:]*:#${user_name}:!:#" \
	"$mountpoint/etc/shadow"

install -d -m 0755 "$mountpoint/var/lib/m1892"
cat >"$mountpoint/etc/m1892-fresh-image" <<EOF
format=m1892-public-base-v1
role=unpersonalized-owner-build-input
root_uuid=$root_uuid
privacy=absent-machine-id,no-host-keys,no-user-keys,no-user-network-credentials,generic-cellular-autoconfig-only
first_boot=direct-phosh-development-session
EOF

for item in \
	m1892-clock:boot m1892-efi-rtc-wake-r331:boot \
	m1892-venus-coldload-r521:boot \
	m1892-rmtfs-shadow:boot m1892-radio-bootstrap:boot \
	m1892-r6-first-boot:default m1892-cellular-prepare:default \
	m1892-power:default m1892-sensors:default m1892-speaker:default \
	m1892-ufs-policy:default 81voltd:default q6voiced:default docker:default; do
	service=${item%%:*}
	runlevel=${item#*:}
	test -x "$mountpoint/etc/init.d/$service" || fail "missing-service:$service"
	ln -snf "/etc/init.d/$service" "$mountpoint/etc/runlevels/$runlevel/$service"
done
rm -f "$mountpoint/etc/runlevels/default/m1892-screen-idle" \
	"$mountpoint/etc/runlevels/default/usb-signaller" \
	"$mountpoint/etc/runlevels/default/nftables" \
	"$mountpoint/etc/runlevels/default/postmarketos-zram-swap" \
	"$mountpoint/etc/runlevels/boot/swclock-offset-boot" \
	"$mountpoint/etc/runlevels/shutdown/swclock-offset-shutdown" \
	"$mountpoint/etc/init.d/m1892-screen-idle" \
	"$mountpoint/usr/local/libexec/m1892-screen-idle.py" \
	"$mountpoint/usr/local/sbin/m1892-screen-idle-launch"

# Seed clean, non-personal desktop and emulator settings. User ROMs, themes, saves and
# scraped media intentionally remain outside this base image.
# `install -d` only applies the requested owner to its final path.  When the
# parent does not yet exist it may be created as root:root, which makes the
# whole GNOME configuration directory unwritable on first boot.  Materialize
# and own every user-visible parent explicitly before installing leaf files.
if test -d "$mountpoint/etc/skel"; then
	(cd "$mountpoint/etc/skel" && tar -cf - .) |
		(cd "$mountpoint$user_home" && tar -xf -)
fi
install -d -m 0755 -o "$user_uid" -g "$user_gid" \
	"$mountpoint$user_home" \
	"$mountpoint$user_home/.config" \
	"$mountpoint$user_home/ES-DE"
retro_dir=$mountpoint$user_home/.config/retroarch
install -d -m 0755 -o "$user_uid" -g "$user_gid" "$retro_dir"
install -m 0644 -o "$user_uid" -g "$user_gid" "$mountpoint/etc/retroarch.cfg" "$retro_dir/retroarch.cfg"
install -m 0644 -o "$user_uid" -g "$user_gid" \
	"$mountpoint/usr/local/share/m1892-r6/retroarch/m1892-esde.cfg" \
	"$retro_dir/m1892-esde.cfg"
install -D -m 0644 \
	"$mountpoint/usr/local/share/m1892-r6/retroarch/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg" \
	"$mountpoint/usr/share/libretro/autoconfig/udev/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg"

set_cfg()
{
	file=$1 key=$2 value=$3
	if grep -q "^${key} = " "$file"; then
		sed -i "s#^${key} = .*#${key} = \"${value}\"#" "$file"
	else
		printf '%s = "%s"\n' "$key" "$value" >>"$file"
	fi
}
retro=$retro_dir/retroarch.cfg
for pair in \
	user_language:12 video_driver:vulkan audio_driver:pulse audio_latency:64 \
	audio_resampler:sinc menu_driver:ozone input_enable_hotkey_btn:15 \
	input_menu_toggle_btn:8 input_exit_emulator_btn:16 input_pause_toggle_btn:5 \
	input_screenshot_btn:6 input_fps_toggle_btn:9 input_save_state_btn:12 \
	input_load_state_btn:11 input_state_slot_increase_btn:h0up \
	input_state_slot_decrease_btn:h0down input_rewind_btn:nul input_rewind_axis:+5 \
	input_hold_fast_forward_btn:nul input_hold_fast_forward_axis:nul \
	input_toggle_fast_forward_btn:nul input_toggle_fast_forward_axis:+4 \
	input_shader_prev_axis:nul input_shader_next_axis:nul quit_press_twice:true; do
	set_cfg "$retro" "${pair%%:*}" "${pair#*:}"
done
set_cfg "$retro" rewind_enable false
chown "$user_uid:$user_gid" "$retro"

ppsspp_root=$mountpoint$user_home/.config/ppsspp
ppsspp_psp=$ppsspp_root/PSP
ppsspp_dir=$ppsspp_psp/SYSTEM
install -d -m 0755 -o "$user_uid" -g "$user_gid" \
	"$ppsspp_root" "$ppsspp_psp" "$ppsspp_dir"
cat >"$ppsspp_dir/ppsspp.ini" <<'EOF'
[General]
FirstRun = False
Language = zh_CN
AutoRun = True
UISound = False

[Graphics]
GraphicsBackend = 0 (OPENGL)
SoftwareRenderer = False
HardwareTransform = True
InternalResolution = 2
FullScreen = True
ImmersiveMode = True
VSync = False
MultiThreading = True

[Sound]
Enable = True
AudioBackend = 0
AudioBufferSize = 256
GameVolume = 100
AutoAudioDevice = True
EOF
chown "$user_uid:$user_gid" "$ppsspp_dir/ppsspp.ini"

es_dir=$mountpoint$user_home/ES-DE/settings
install -d -m 0755 -o "$user_uid" -g "$user_gid" "$es_dir"
cat >"$es_dir/es_settings.xml" <<EOF
<?xml version="1.0"?>
<bool name="ParseGamelistOnly" value="true" />
<bool name="ScraperOverwriteData" value="false" />
<bool name="ViewsVideoAudio" value="true" />
<bool name="NavigationSounds" value="true" />
<bool name="ShowQuitMenu" value="false" />
<int name="MaxVRAM" value="512" />
<int name="SoundVolumeNavigation" value="70" />
<int name="SoundVolumeVideos" value="80" />
<string name="ApplicationLanguage" value="zh_CN" />
<string name="InputControllerType" value="xbox" />
<string name="ROMDirectory" value="$user_home/ROMs" />
EOF
chown "$user_uid:$user_gid" "$es_dir/es_settings.xml"

# This is a privacy-clean distribution home, not an in-place user-data
# migration.  No root-managed object belongs below it.  Normalize the complete
# tree once, after every payload has been installed, so a newly introduced
# parent can never recreate the first-boot permission failure.
chown -R "$user_uid:$user_gid" "$mountpoint$user_home"

sync
umount "$mountpoint"
mounted=no
fsck_repair "$image"
# Use ext4's traditional orphan list for robust recovery after abrupt power
# cuts. orphan_file is only a scalability optimization on this single-user
# phone and is not required by the filesystem contract.
tune2fs -O ^orphan_file "$image" >/dev/null
fsck_repair "$image"
echo "image=$image"
sha256sum "$image"
echo M1892_FRESH_FINALIZE_PASS
