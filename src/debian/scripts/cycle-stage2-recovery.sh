#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(git -C "$script_dir" rev-parse --show-toplevel)
recovery=${1:-}
rootfs=${2:-}
stage=${M1892_DEBIAN_STAGE:-2}
case "$stage" in 2|3) ;; *) echo 'M1892_DEBIAN_CYCLE_FAIL: invalid-stage' >&2; exit 2 ;; esac
[ -f "$recovery" ] && [ -f "$rootfs" ] || {
	echo "usage: $0 STAGE${stage}_RECOVERY ROOTFS_EXT4_GZ" >&2
	exit 2
}
shared_tools=${M1892_SHARED_TOOLS:-$project_dir/research/mainline/tools}
[ -f "$shared_tools/push-m1892-ncm.ps1" ] && \
	[ -f "$shared_tools/invoke-m1892-serial.ps1" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: audited shared transfer tools absent' >&2
	exit 2
}
fastboot=${FASTBOOT:-/mnt/c/Program Files/platform-tools/fastboot.exe}
[ -x "$fastboot" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: fastboot absent' >&2
	exit 2
}
[ "$(stat -c %s "$recovery")" = 67108864 ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: recovery-size' >&2
	exit 2
}
[ -f "$rootfs.sha256" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: rootfs-sidecar-absent' >&2
	exit 2
}
(cd "$(dirname -- "$rootfs")" && sha256sum -c "$(basename -- "$rootfs").sha256") \
	>/dev/null || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: rootfs-sidecar-hash' >&2
	exit 2
}
recovery_metadata=$(dirname -- "$recovery")/BUILD-METADATA.txt
[ -r "$recovery_metadata" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: recovery-metadata-absent' >&2
	exit 2
}
rootfs_sha=$(sha256sum "$rootfs" | awk '{print $1}')
rootfs_bytes=$(stat -c %s "$rootfs")
[ "$(sed -n 's/^rootfs_sha256=//p' "$recovery_metadata")" = "$rootfs_sha" ] &&
	[ "$(sed -n 's/^rootfs_size=//p' "$recovery_metadata")" = "$rootfs_bytes" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: recovery-rootfs-bundle-mismatch' >&2
	exit 2
}

fastboot_devices()
{
	"$fastboot" devices 2>/dev/null | tr -d '\r'
}

device_lines=$(fastboot_devices)
if [ -z "$device_lines" ]; then
	ssh_host=${M1892_CURRENT_SSH_HOST:-}
	[ -n "$ssh_host" ] || {
		echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: set M1892_CURRENT_SSH_HOST after authenticated discovery' >&2
		exit 3
	}
	model=$(timeout 10 ssh "root@$ssh_host" \
		'tr -d "\000" </sys/firmware/devicetree/base/model' </dev/null) || {
		echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: authenticated-ssh-unavailable' >&2
		exit 3
	}
	[ "$model" = 'Meizu 16th Plus (M1892)' ] || {
		echo "M1892_DEBIAN_STAGE2_CYCLE_FAIL: wrong-ssh-device:$model" >&2
		exit 3
	}
	# Use the accepted synchronized wrapper from the running system.  No new
	# key, alternate client or host-key bypass is introduced here.
	timeout 30 ssh "root@$ssh_host" \
		'/usr/local/sbin/m1892-safe-fastboot bootloader' </dev/null || true
	attempt=0
	while [ "$attempt" -lt 75 ]; do
		device_lines=$(fastboot_devices)
		[ -z "$device_lines" ] || break
		attempt=$((attempt + 1))
		sleep 2
	done
fi

device_count=$(printf '%s\n' "$device_lines" | awk 'NF { count++ } END { print count + 0 }')
serial=$(printf '%s\n' "$device_lines" | awk 'NF { print $1 }')
[ "$device_count" -eq 1 ] && [ -n "$serial" ] || {
	echo "M1892_DEBIAN_STAGE2_CYCLE_FAIL: fastboot-device-count:$device_count" >&2
	exit 3
}
getvar()
{
	"$fastboot" -s "$serial" getvar "$1" 2>&1 | tr -d '\r' |
		sed -n -e "s/^(bootloader) $1: //p" -e "s/^$1: //p" | tail -n 1
}
[ "$(getvar product)" = M1892 ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: wrong-fastboot-product' >&2
	exit 3
}
[ "$(getvar unlocked)" = yes ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: bootloader-locked' >&2
	exit 3
}

# This is the only device-mutating step: recovery only.  Persistent boot and
# userdata are not written.
recovery_win=$(wslpath -w "$(readlink -f "$recovery")")
"$fastboot" -s "$serial" flash recovery "$recovery_win"
"$fastboot" -s "$serial" oem reboot recovery

attempt=0
while [ "$attempt" -lt 210 ]; do
	port_count=$(powershell.exe -NoProfile -Command \
		'$d=@(Get-PnpDevice -PresentOnly | Where-Object { $_.Class -eq "Ports" -and $_.InstanceId -like "USB\VID_1D6B&PID_0104*" }); Write-Output $d.Count' \
		</dev/null | tr -d '\r' | tail -n 1)
	[ "$port_count" = 1 ] && break
	attempt=$((attempt + 1))
	sleep 2
done
[ "$port_count" = 1 ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: recovery-acm-timeout' >&2
	exit 4
}

push_script_win=$(wslpath -w "$shared_tools/push-m1892-ncm.ps1")
# Windows PowerShell 5 cannot reliably pass a WSL UNC path to
# File.ReadAllBytes.  Stage the already verified compressed artifact in the
# host's own temporary directory, then verify the copy before transfer.
rootfs_sha=$(sha256sum "$rootfs" | awk '{print $1}')
windows_temp=$(powershell.exe -NoProfile -Command '[IO.Path]::GetTempPath()' \
	</dev/null | tr -d '\r' | tail -n 1)
[ -n "$windows_temp" ] || {
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: windows-temp-unavailable' >&2
	exit 4
}
rootfs_win="${windows_temp}m1892-debian13-stage${stage}-${rootfs_sha}.ext4.gz"
rootfs_host=$(wslpath -u "$rootfs_win")
mkdir -p "$(dirname -- "$rootfs_host")"
cp "$rootfs" "$rootfs_host"
[ "$(sha256sum "$rootfs_host" | awk '{print $1}')" = "$rootfs_sha" ] || {
	rm -f "$rootfs_host"
	echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: windows-stage-hash' >&2
	exit 4
}
cleanup_host_copy() { rm -f "$rootfs_host"; }
trap cleanup_host_copy EXIT HUP INT TERM
attempt=0
until powershell.exe -NoProfile -ExecutionPolicy Bypass \
	-File "$push_script_win" -Source "$rootfs_win" \
	-Destination "/run/m1892-debian13-stage${stage}-rootfs.ext4.gz"
do
	attempt=$((attempt + 1))
	[ "$attempt" -lt 12 ] || {
		echo 'M1892_DEBIAN_STAGE2_CYCLE_FAIL: NCM transfer timeout' >&2
		exit 4
	}
	sleep 5
done
rm -f "$rootfs_host"
trap - EXIT HUP INT TERM

serial_script_win=$(wslpath -w "$shared_tools/invoke-m1892-serial.ps1")
attempt=0
while [ "$attempt" -lt 80 ]; do
	output=$(powershell.exe -NoProfile -ExecutionPolicy Bypass \
		-File "$serial_script_win" -TimeoutSeconds 10 \
		-Command "if [ -x /usr/bin/cat ]; then /usr/bin/cat /run/m1892-debian13-stage${stage}-pass; else /bin/cat /run/m1892-debian13-stage${stage}-pass; fi" 2>&1 || true)
	printf '%s\n' "$output" | tr -d '\r'
	if printf '%s\n' "$output" | grep -q 'result=pass' && \
		printf '%s\n' "$output" | grep -q 'pid1=systemd' && \
		printf '%s\n' "$output" | grep -q 'block_mounts=none'; then
		echo "M1892_DEBIAN_STAGE${stage}_RUNTIME_PASS"
		echo 'Only recovery was flashed; Debian and all runtime state are in RAM.'
		exit 0
	fi
	attempt=$((attempt + 1))
	sleep 5
done
echo "M1892_DEBIAN_STAGE${stage}_CYCLE_FAIL: systemd acceptance marker timeout" >&2
exit 4
