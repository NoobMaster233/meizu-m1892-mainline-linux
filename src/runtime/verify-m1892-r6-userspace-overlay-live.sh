#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
archive=$script_dir/artifacts/m1892-mainline-daily-2026.08-r6-userspace-overlay.tar.gz
member=m1892-mainline-daily-2026.08-r6-userspace-overlay/PAYLOAD_MANIFEST.tsv
phone=${M1892_SSH_HOST:-}
test -n "$phone" || { echo M1892_R6_OVERLAY_LIVE_VERIFY_FAIL: M1892_SSH_HOST-required >&2; exit 2; }
test -s "$archive" || { echo M1892_R6_OVERLAY_LIVE_VERIFY_FAIL: archive-missing >&2; exit 1; }

# The manifest is streamed directly to the phone; no persistent or /run file is
# created. Two packaged templates map to their supported active destinations.
tar -xOzf "$archive" "$member" | ssh root@"$phone" 'set -eu
record=$(getent passwd | awk -F: '\''
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
'\'')
daily_home=$(printf "%s\n" "$record" | cut -d: -f6)
count=0
while IFS="	" read -r mode size expected target; do
	case "$target" in
	/usr/local/share/m1892-r6/retroarch/m1892-esde.cfg)
		live=$daily_home/.config/retroarch/m1892-esde.cfg ;;
	/usr/local/share/m1892-r6/retroarch/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg)
		live=/usr/share/libretro/autoconfig/udev/GAMESIR_GameSir-X2_Pro-Xbox_M1892.cfg ;;
	*) live=$target ;;
	esac
	test -f "$live" || { echo "M1892_R6_OVERLAY_LIVE_VERIFY_FAIL: missing:$live" >&2; exit 1; }
	test "$(stat -c %s "$live")" = "$size" || { echo "M1892_R6_OVERLAY_LIVE_VERIFY_FAIL: size:$live" >&2; exit 1; }
	test "$(sha256sum "$live" | cut -d" " -f1)" = "$expected" || { echo "M1892_R6_OVERLAY_LIVE_VERIFY_FAIL: hash:$live" >&2; exit 1; }
	count=$((count + 1))
done
test "$(readlink /opt/m1892/sdl2-native/usr/lib/libSDL2-2.0.so.0)" = \
	libSDL2-2.0.so.0.3200.10
test "$(readlink /opt/m1892/sdl2-native/usr/lib/libSDL2-2.0.so)" = \
	libSDL2-2.0.so.0
echo "live_payload_files=$count"
echo M1892_R6_OVERLAY_LIVE_CONTENT_PASS'
