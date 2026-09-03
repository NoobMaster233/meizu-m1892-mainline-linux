#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

mode=${1:-}
case "$mode" in
	--check)
		shift
		write=no
		resume=no
		;;
	--flash)
		shift
		confirmation=${1:-}
		shift || true
		[ "$confirmation" = ERASE-M1892-USERDATA ] || {
			echo "Refusing write: exact confirmation is ERASE-M1892-USERDATA" >&2
			exit 2
		}
		write=yes
		resume=no
		;;
	--resume-boot)
		shift
		confirmation=${1:-}
		shift || true
		[ "$confirmation" = FLASH-M1892-BOOT ] || {
			echo "Refusing write: exact confirmation is FLASH-M1892-BOOT" >&2
			exit 2
		}
		write=yes
		resume=yes
		;;
	*)
		echo "usage: $0 --check USERDATA_SPARSE BOOT_IMG" >&2
		echo "       $0 --flash ERASE-M1892-USERDATA USERDATA_SPARSE BOOT_IMG" >&2
		echo "       $0 --resume-boot FLASH-M1892-BOOT BOOT_IMG" >&2
		exit 2
		;;
esac

if [ "$resume" = yes ]; then
	userdata=
	boot=${1:-}
else
	userdata=${1:-}
	boot=${2:-}
	[ -f "$userdata" ] || { echo "missing userdata image: $userdata" >&2; exit 1; }
fi
[ -f "$boot" ] || { echo "missing boot image: $boot" >&2; exit 1; }
command -v fastboot >/dev/null 2>&1 || { echo "fastboot is required" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "sha256sum is required" >&2; exit 1; }
command -v timeout >/dev/null 2>&1 || { echo "timeout is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
fastboot_command=$(command -v fastboot)
fastboot_resolved=$(readlink -f "$fastboot_command" 2>/dev/null || printf '%s\n' "$fastboot_command")
case "$fastboot_resolved" in
	*.exe)
		command -v wslpath >/dev/null 2>&1 || {
			echo "wslpath is required when Windows fastboot.exe is used from WSL" >&2
			exit 1
		}
		fastboot_path() { wslpath -w "$1"; }
		;;
	*)
		fastboot_path() { printf '%s\n' "$1"; }
		;;
esac
probe_timeout=${M1892_FASTBOOT_PROBE_TIMEOUT:-2}
case "$probe_timeout" in
	''|*[!0-9]*|0) echo "invalid M1892_FASTBOOT_PROBE_TIMEOUT" >&2; exit 1 ;;
esac

verify_sidecar()
{
	file=$1
	sidecar=$file.sha256
	[ -f "$sidecar" ] || { echo "missing SHA-256 sidecar: $sidecar" >&2; exit 1; }
	expected=$(awk 'NR==1 {print $1}' "$sidecar")
	case "$expected" in
		????????????????????????????????????????????????????????????????) ;;
		*) echo "invalid SHA-256 sidecar: $sidecar" >&2; exit 1 ;;
	esac
	actual=$(sha256sum "$file" | awk '{print $1}')
	[ "$actual" = "$expected" ] || { echo "SHA-256 mismatch: $file" >&2; exit 1; }
	verified_sha256=$actual
}

[ "$resume" = yes ] || {
	verify_sidecar "$userdata"
	userdata_sha256=$verified_sha256
}
verify_sidecar "$boot"
boot_sha256=$verified_sha256
[ "$boot_sha256" = 7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526 ] || {
	echo "boot image is not the audited image for this public release" >&2
	exit 1
}
[ "$(stat -c %s "$boot")" -eq 67108864 ] || {
	echo "boot image is not exactly 64 MiB" >&2
	exit 1
}
if [ "$resume" = no ]; then
	magic=$(od -An -tx4 -N4 "$userdata" | tr -d ' \n')
	[ "$magic" = ed26ff3a ] || {
		echo "userdata is not an Android sparse image (magic=$magic)" >&2
		exit 1
	}
	"$script_dir/img2fullsimg.py" --verify "$userdata"
	logical_bytes=$(python3 - "$userdata" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as stream:
    header = stream.read(28)
if len(header) != 28:
    raise SystemExit("short sparse header")
magic, major, minor, file_header, chunk_header, block_size, total_blocks, total_chunks, checksum = struct.unpack(
    "<I4H4I", header
)
print(block_size * total_blocks)
PY
	)
	[ "$logical_bytes" -eq 8589934592 ] || {
		echo "userdata logical size is not exactly 8 GiB: $logical_bytes" >&2
		exit 1
	}
fi

identify_target()
{
	# Windows fastboot can leave an apparently present PnP interface whose
	# control endpoint no longer responds after a multi-GiB sparse transfer.
	# Bound every individual command as well as the outer retry loop; otherwise
	# one getvar can hang forever and defeat the nominal 15-second settle.
	devices=$(timeout "$probe_timeout" fastboot devices 2>/dev/null |
		tr -d '\r' | awk 'NF {print $1}') || return 1
	[ "$(printf '%s\n' "$devices" | awk 'NF {n++} END {print n+0}')" -eq 1 ] ||
		return 1
	serial=$devices
	case "$serial" in *\?*) return 1 ;; esac
	product=$(timeout "$probe_timeout" fastboot -s "$serial" getvar product 2>&1 |
		tr -d '\r' |
		sed -n 's/^product: //p' | head -1)
	unlocked=$(timeout "$probe_timeout" fastboot -s "$serial" getvar unlocked 2>&1 |
		tr -d '\r' |
		sed -n 's/^unlocked: //p' | head -1)
	[ "$product" = M1892 ] && [ "$unlocked" = yes ]
}

identify_target || {
	echo "exactly one responsive, unlocked M1892 fastboot target is required" >&2
	echo "If fastboot shows ????????????, physically replug USB or re-enter fastboot." >&2
	exit 1
}

echo "M1892_FLASH_PREFLIGHT_PASS"
[ "$resume" = yes ] ||
	echo "userdata_sha256=$userdata_sha256"
echo "boot_sha256=$boot_sha256"

[ "$write" = yes ] || {
	echo "write_performed=no"
	exit 0
}

if [ "$resume" = no ]; then
	# M1892's bootloader does not implement a bounded, reliable userdata erase.
	# The verified full-sparse transport contains RAW chunks only, so it replaces
	# every byte of the 8-GiB ext4 image instead of preserving stale bytes through
	# Android sparse DONT_CARE chunks.
	fastboot -s "$serial" flash userdata "$(fastboot_path "$userdata")"
fi
# Some Windows/WSL fastboot stacks release and reopen the bootloader USB
# interface between large sparse transfers.  A short bounded settle avoids a
# back-to-back open racing that re-enumeration; native Linux fastboot is
# unaffected apart from the delay.
attempt=0
while ! identify_target; do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 15 ] || {
		echo "userdata write completed, but fastboot did not re-enumerate cleanly" >&2
		echo "Replug USB/re-enter fastboot, then use --resume-boot." >&2
		exit 3
	}
	sleep 1
done
fastboot -s "$serial" flash boot "$(fastboot_path "$boot")"
echo "M1892_FLASH_WRITE_PASS"
echo "The phone remains in fastboot. Review the log, then run fastboot reboot manually."
