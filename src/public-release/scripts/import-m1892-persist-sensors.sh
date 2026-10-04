#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

# Import factory sensor registry/calibration from this phone's untouched
# persist partition.  The partition is mounted read-only with journal replay
# disabled and is never included in a redistributable image.

mode=${1:---check}
target=${2:-/usr/share/qcom/sdm845/Meizu/m1892/sensors}
case $mode in --check|--install) ;; *) echo "usage: $0 [--check|--install [TARGET]]" >&2; exit 2 ;; esac

fail() { echo "M1892_PERSIST_SENSOR_IMPORT_FAIL: $*" >&2; exit 1; }
model=$(tr -d '\000' </sys/firmware/devicetree/base/model 2>/dev/null || true)
[ "$model" = 'Meizu 16th Plus (M1892)' ] || fail "hardware:$model"
device=/dev/disk/by-partlabel/persist
[ -b "$device" ] || fail missing-persist
[ "$(blkid -s TYPE -o value "$device")" = ext4 ] || fail persist-not-ext4

mountpoint=$(mktemp -d /run/m1892-persist-ro.XXXXXX)
cleanup()
{
	umount "$mountpoint" 2>/dev/null || true
	rmdir "$mountpoint" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mount -t ext4 -o ro,noload "$device" "$mountpoint"

config=$mountpoint/sensors/registry/config
registry=$mountpoint/sensors/registry/registry
[ -d "$config" ] || fail missing-sensor-config
[ -d "$registry" ] || fail missing-sensor-registry
config_count=$(find "$config" -type f | wc -l)
registry_count=$(find "$registry" -type f | wc -l)
[ "$config_count" -ge 30 ] || fail "config-count:$config_count"
[ "$registry_count" -ge 100 ] || fail "registry-count:$registry_count"

if [ "$mode" = --install ]; then
	install -d -m 0755 "$target/config" "$target/registry"
	cp -a "$config/." "$target/config/"
	cp -a "$registry/." "$target/registry/"
	find "$target/config" "$target/registry" -type f -exec chmod 0644 {} +
	# hexagonrpcd translates Android's /vendor/etc/sensors/sns_reg_config to
	# this top-level path.  The per-device persist tree stores the source in
	# registry/, so materialize the mapping after every read-only import.
	[ -s "$target/registry/sns_reg_config" ] || fail missing-sns-reg-config
	cp "$target/registry/sns_reg_config" "$target/sns_reg.conf"
	chmod 0644 "$target/sns_reg.conf"
fi

echo "config_files=$config_count registry_files=$registry_count"
echo "M1892_PERSIST_SENSOR_IMPORT_PASS mode=$mode"
