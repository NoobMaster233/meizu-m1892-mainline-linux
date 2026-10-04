#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

root=${1:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -n "$root" ] && [ -d "$root" ] || {
	echo 'M1892_DEBIAN_STAGE3_FINALIZE_FAIL: expected-root-directory' >&2
	exit 2
}

"$script_dir/finalize-minimal-rootfs.sh" "$root"

# The generic artifact has no owner yet, therefore neither remote login nor an
# automatic graphical login is enabled here.  The Recovery-only live harness
# creates its disposable test owner in RAM; the persistent installer will use
# a standard owner-initialization flow in a later stage.
find "$root/etc/systemd/system" -type l \
	\( -name 'ssh.service' -o -name 'sshd.service' \) -delete 2>/dev/null || true

# Default product locale is Simplified Chinese.  English remains installed and
# selectable through Plasma.  locale-gen is provided by Debian's locales
# package and runs inside mmdebstrap's arm64 chroot through binfmt.
printf '%s\n' 'en_US.UTF-8 UTF-8' 'zh_CN.UTF-8 UTF-8' >"$root/etc/locale.gen"
printf '%s\n' 'LANG=zh_CN.UTF-8' >"$root/etc/default/locale"
locale_gen=$root/usr/sbin/locale-gen
[ -x "$locale_gen" ] || {
	echo 'M1892_DEBIAN_STAGE3_FINALIZE_FAIL: locale-gen-absent' >&2
	exit 1
}
chroot "$root" /usr/sbin/locale-gen >/dev/null

# Sensor userspace is taken from Debian forky as a narrowly pinned backport.
# Do not leave that suite enabled for ordinary runtime upgrades on Debian 13.
. "$script_dir/../config/stage3.env"
components=$(printf '%s' "$M1892_DEBIAN_COMPONENTS" | tr ',' ' ')
cat >"$root/etc/apt/sources.list" <<EOF
deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE $components
deb [check-valid-until=no] $M1892_DEBIAN_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-updates $components
deb [check-valid-until=no] $M1892_DEBIAN_SECURITY_MIRROR/$M1892_DEBIAN_SNAPSHOT $M1892_DEBIAN_SUITE-security $components
EOF
find "$root/etc/apt/sources.list.d" -type f -delete 2>/dev/null || true

# The recovery prototype has no owner password with which Polkit could approve
# a privileged timezone change.  Ship the Chinese default as ordinary systemd
# timezone configuration so Plasma's first-run UI does not present an
# impossible authentication prompt.  A persistent owner may change it later.
[ -e "$root/usr/share/zoneinfo/Asia/Shanghai" ] || {
	echo 'M1892_DEBIAN_STAGE3_FINALIZE_FAIL: timezone-data-absent' >&2
	exit 1
}
ln -snf /usr/share/zoneinfo/Asia/Shanghai "$root/etc/localtime"
printf 'Asia/Shanghai\n' >"$root/etc/timezone"

# These files describe the build host and wall-clock installation event, not
# the installed package contract.  ldconfig recreates its auxiliary cache as
# needed and dpkg's authoritative state is /var/lib/dpkg/status.  Canonicalize
# both so two builds from the frozen snapshot are byte reproducible.
rm -f "$root/var/cache/ldconfig/aux-cache"
: >"$root/var/log/dpkg.log"

echo M1892_DEBIAN_STAGE3_FINALIZE_PASS
