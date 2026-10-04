#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

root=${1:-}
[ -n "$root" ] && [ -d "$root" ] || {
	echo 'M1892_DEBIAN_FINALIZE_FAIL: expected-root-directory' >&2
	exit 2
}
root=$(readlink -f "$root")
[ "$root" != / ] && [ -f "$root/etc/debian_version" ] && \
	[ -s "$root/var/lib/dpkg/status" ] || {
	echo 'M1892_DEBIAN_FINALIZE_FAIL: unsafe-or-unidentified-root' >&2
	exit 2
}

# Generic images must acquire these identities on their own first boot.
rm -f "$root/etc/hostname" "$root/var/lib/dbus/machine-id" \
	"$root/var/lib/systemd/random-seed"
: >"$root/etc/machine-id"

# Never ship builder SSH identities or owner network profiles.
find "$root/etc/ssh" -maxdepth 1 -type f -name 'ssh_host_*' -delete
if [ -d "$root/etc/NetworkManager/system-connections" ]; then
	find "$root/etc/NetworkManager/system-connections" -mindepth 1 -delete
fi
rm -rf "$root/root/.ssh"

# NetworkManager owns the runtime resolver state on this product line.
rm -f "$root/etc/resolv.conf"
ln -s ../run/NetworkManager/resolv.conf "$root/etc/resolv.conf"

# Remove build-host state without changing packaged defaults.  Do not empty
# /tmp here: mmdebstrap keeps its rootless APT configuration there until its
# own cleanup phase has completed.
rm -f "$root/root/.bash_history" "$root/root/.wget-hsts"

echo M1892_DEBIAN_MINIMAL_FINALIZE_PASS
