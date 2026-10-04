#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
artifact=${1:-}
evidence_dir=${2:-}
config=${3:-$tree_dir/config/rootfs.env.example}
[ -r "$artifact" ] && [ -n "$evidence_dir" ] && [ -r "$config" ] || {
	echo "usage: $0 ROOTFS_TAR EVIDENCE_DIR [CONFIG]" >&2
	exit 2
}
mkdir -p "$evidence_dir"

# shellcheck disable=SC1090
. "$config"
fail() { echo "M1892_DEBIAN_ROOTFS_VERIFY_FAIL: $*" >&2; exit 1; }

archive_list=$evidence_dir/archive-files.txt
tar --numeric-owner -tf "$artifact" >"$archive_list"
awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ { exit 1 }' "$archive_list" || fail unsafe-archive-path

work=$(mktemp -d /tmp/m1892-debian-rootfs-verify.XXXXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
tar --no-same-owner --exclude='./dev/*' -xf "$artifact" -C "$work"

[ -r "$work/etc/os-release" ] || fail missing-os-release
grep -Fxq 'ID=debian' "$work/etc/os-release" || fail wrong-os-id
grep -Eq '^VERSION_ID="?13"?$' "$work/etc/os-release" || fail wrong-os-version
[ "$(readlink -f "$work/sbin/init")" = "$work/usr/lib/systemd/systemd" ] || fail wrong-init
[ -x "$work/usr/lib/systemd/systemd" ] || fail missing-systemd
[ -s "$work/var/lib/dpkg/status" ] || fail missing-dpkg-status

[ -f "$work/etc/machine-id" ] && [ ! -s "$work/etc/machine-id" ] || fail machine-id-not-empty
[ ! -e "$work/var/lib/dbus/machine-id" ] || fail dbus-machine-id-present
[ ! -e "$work/etc/hostname" ] || fail hostname-present
[ "$(readlink "$work/etc/resolv.conf")" = ../run/NetworkManager/resolv.conf ] || fail wrong-resolv-conf
find "$work/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -print -quit | grep -q . && fail ssh-host-key-present
find "$work/etc/NetworkManager/system-connections" -mindepth 1 -print -quit 2>/dev/null | grep -q . && fail network-profile-present
find "$work/root" "$work/home" -path '*/.ssh/*' -print -quit 2>/dev/null | grep -q . && fail owner-ssh-data-present

awk -F: '$3 >= 1000 && $3 != 65534 { exit 1 }' "$work/etc/passwd" || fail regular-user-present
awk -F: '$2 !~ /^[!*]/ { exit 1 }' "$work/etc/shadow" || fail unlocked-password-present

status=$work/var/lib/dpkg/status
printf '%s' "$M1892_DEBIAN_BASE_PACKAGES" | tr ',' '\n' | while IFS= read -r package; do
	awk -v wanted="$package" '
		$1 == "Package:" { package=$2 }
		$1 == "Status:" && package == wanted && $0 == "Status: install ok installed" { found=1 }
		END { exit(found ? 0 : 1) }
	' "$status" || fail "base-package-not-installed:$package"
done

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

if awk -F '\t' '$3 != "arm64" && $3 != "all" { exit 1 }' "$evidence_dir/packages.tsv"; then :; else
	fail foreign-package-architecture
fi

: >"$evidence_dir/licenses.tsv"
while IFS="$(printf '\t')" read -r package version architecture; do
	copyright=$work/usr/share/doc/$package/copyright
	[ -r "$copyright" ] || fail "missing-package-copyright:$package"
	printf '%s\t%s\t%s\n' "$package" "usr/share/doc/$package/copyright" \
		"$(sha256sum "$copyright" | awk '{print $1}')" \
		>>"$evidence_dir/licenses.tsv"
done <"$evidence_dir/packages.tsv"

(cd "$work" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
	>"$evidence_dir/files.sha256"
tar --numeric-owner --full-time -tvf "$artifact" >"$evidence_dir/tar-metadata.txt"

if grep -RIlE 'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|(^|[[:space:]])psk=|ssid=' \
	"$work/etc" "$work/root" "$work/home" 2>/dev/null | grep -q .; then
	fail private-material-pattern
fi

artifact_sha=$(sha256sum "$artifact" | awk '{print $1}')
printf 'artifact_sha256=%s\n' "$artifact_sha" >"$evidence_dir/verification.env"
printf 'package_count=%s\n' "$(wc -l <"$evidence_dir/packages.tsv")" >>"$evidence_dir/verification.env"
printf 'license_record_count=%s\n' "$(wc -l <"$evidence_dir/licenses.tsv")" >>"$evidence_dir/verification.env"
printf 'regular_file_count=%s\n' "$(wc -l <"$evidence_dir/files.sha256")" >>"$evidence_dir/verification.env"
printf 'result=pass\n' >>"$evidence_dir/verification.env"

cat "$evidence_dir/verification.env"
echo M1892_DEBIAN_MINIMAL_ROOTFS_VERIFY_PASS
