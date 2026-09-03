#!/bin/sh
# Phone-oriented RetroArch entry point selected by ES-DE through PATH.
# /usr/bin/retroarch remains available for diagnostics without this policy.

set -eu

record=$(getent passwd | awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
') || {
	printf '%s\n' 'M1892_RETROARCH_ESDE_FAIL: expected exactly one regular user' >&2
	exit 1
}
home=$(printf '%s\n' "$record" | cut -d: -f6)
case $home in /home/*) ;; *) exit 1 ;; esac
override=$home/.config/retroarch/m1892-esde.cfg

if [ ! -r "$override" ]; then
	printf '%s\n' "M1892_RETROARCH_ESDE_FAIL: override missing: $override" >&2
	exit 1
fi

exec /usr/bin/retroarch --fullscreen --appendconfig "$override" "$@"
