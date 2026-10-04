#!/bin/sh
# SPDX-License-Identifier: MIT
# Perform one real systemd s2idle cycle and validate the same M1892 session after resume.
set -eu

outdir=
fail()
{
	reason=$*
	if [ -n "$outdir" ] && [ -d "$outdir" ]; then
		{
			echo failure_reason="$reason"
			echo result=fail
		} >>"$outdir/result"
		sync -f "$outdir/result" 2>/dev/null || sync
	fi
	echo "M1892_S2IDLE_FAIL: $reason" >&2
	exit 1
}
cellular_acceptance=${M1892_CELLULAR_ACCEPTANCE:-/usr/libexec/m1892/cellular-acceptance}
cellular_resume_timeout=${M1892_CELLULAR_RESUME_TIMEOUT_SECONDS:-180}
case $cellular_acceptance in
	/usr/libexec/m1892/cellular-acceptance|/run/m1892-cellular-acceptance) ;;
	*) fail invalid-cellular-acceptance-path ;;
esac
case $cellular_resume_timeout in ''|*[!0-9]*) fail invalid-cellular-timeout ;; esac
[ "$cellular_resume_timeout" -le 300 ] || fail cellular-timeout-too-long
[ "$cellular_resume_timeout" -ge 30 ] || fail cellular-timeout-too-short
[ -x "$cellular_acceptance" ] || fail cellular-acceptance-missing
qcom_count()
{
	awk '/^Count:/ {print $2; exit}' "/sys/kernel/debug/qcom_stats/$1" 2>/dev/null || echo unavailable
}
wifi_failure_count()
{
	journalctl -k -b --no-pager 2>/dev/null |
		grep -Eci 'ath10k.*(failed to suspend hif|failed to install key)|wlan0: failed to remove key' || true
}
suspend_kernel_failure_count()
{
	journalctl -k -b --no-pager 2>/dev/null |
		grep -Eci 'rcu.*(detected stalls|self-detected stall)|Sending NMI from CPU|watchdog: BUG|soft lockup|hard LOCKUP|blocked for more than' || true
}
systemd_watchdog_failure_count()
{
	journalctl -b --no-pager 2>/dev/null |
		grep -Eci 'systemd-(journald|udevd|logind)\.service: Watchdog timeout' || true
}
wait_ufs_runtime_suspended()
{
	host=/sys/bus/platform/devices/1d84000.ufshc
	lun=/sys/class/scsi_host/host0/device
	[ -d "$host" ] && [ -d "$lun" ] || return 1
	waited_ufs=0
	while { [ "$(cat "$host/power/runtime_status")" != suspended ] ||
		[ "$(cat "$lun/power/runtime_status")" != suspended ]; } &&
		[ "$waited_ufs" -lt 300 ]; do
		waited_ufs=$((waited_ufs + 1))
		sleep 0.1
	done
	[ "$waited_ufs" -lt 300 ]
}
ufs_clock_refs_zero()
{
	summary=/sys/kernel/debug/clk/clk_summary
	[ -r "$summary" ] || return 1
	clocks='gcc_ufs_phy_tx_symbol_0_clk
gcc_ufs_phy_rx_symbol_0_clk
gcc_ufs_phy_rx_symbol_1_clk
gcc_ufs_phy_ahb_clk
gcc_ufs_phy_ice_core_clk
gcc_ufs_phy_unipro_core_clk
gcc_aggre_ufs_phy_axi_clk
gcc_ufs_phy_axi_clk'
	for clock in $clocks; do
		counts=$(awk -v name="$clock" '$1 == name {print $2 ":" $3; found++}
			END {if (found != 1) exit 1}' "$summary") || return 1
		[ "$counts" = 0:0 ] || return 1
	done
}
last_pm_timestamp()
{
	pattern=$1
	journalctl -k -b --no-pager -o short-monotonic 2>/dev/null |
		awk -v pattern="$pattern" 'index($0, pattern) { value=$2 }
			END { gsub(/\]/, "", value); print value }'
}
boottime_now()
{
	python3 -c 'import time; print(f"{time.clock_gettime(time.CLOCK_BOOTTIME):.6f}")'
}
pmic_rtc_epoch()
{
	for rtc in /sys/class/rtc/rtc*; do
		[ -d "$rtc" ] || continue
		[ "$(cat "$rtc/name" 2>/dev/null || true)" = \
			'rtc-pm8xxx c440000.spmi:pmic@0:rtc@6000' ] || continue
		cat "$rtc/since_epoch" 2>/dev/null || echo unavailable
		return
	done
	echo unavailable
}

[ "$(id -u)" = 0 ] || fail root-required
[ "$(tr -d '\000' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] ||
	fail wrong-hardware
grep -Fxq 'suspend_policy=manual' /etc/m1892-rootfs-identity || fail wrong-policy
[ "$(cat /sys/power/mem_sleep)" = '[s2idle]' ] || fail s2idle-unavailable
[ "$(systemctl is-enabled suspend.target)" != masked ] || fail suspend-target-masked
[ "$(systemctl is-enabled hibernate.target)" = masked ] || fail hibernate-target-open
systemctl is-active --quiet m1892-wake-policy.service || fail wake-policy-inactive
grep -Fxq 'efi_wakeup=disabled' /run/m1892-wake-policy.state || fail efi-wakeup-policy
grep -Fxq 'power_key_wakeup=enabled' /run/m1892-wake-policy.state || fail power-key-policy
[ -r /sys/devices/platform/soc@0/18800000.wifi/power/wakeup ] ||
	fail wifi-wakeup-absent
[ "$(cat /sys/devices/platform/soc@0/18800000.wifi/power/wakeup)" = disabled ] ||
	fail wifi-system-wakeup-enabled
wifi_connection=$(nmcli -g GENERAL.CONNECTION device show wlan0 2>/dev/null || true)
[ -n "$wifi_connection" ] && [ "$wifi_connection" != -- ] || fail wifi-not-connected
[ "$(nmcli -g 802-11-wireless.wake-on-wlan connection show "$wifi_connection")" = 0x0 ] ||
	fail wifi-profile-wakeup-enabled
iw phy phy0 wowlan show 2>/dev/null | grep -Fxq 'WoWLAN is disabled.' ||
	fail wifi-firmware-wowlan-enabled
[ "$(cat /sys/class/block/sda/device/state)" = running ] || fail ufs-pre
[ "$(cat /sys/fs/ext4/sda19/errors_count)" = 0 ] || fail ext4-pre

owner=$(sed -n 's/^owner=//p' /var/lib/m1892/oem-owner-created)
uid=$(id -u "$owner")
kwin_pid=$(pgrep -o -u "$uid" -x kwin_wayland 2>/dev/null || true)
[ -n "$kwin_pid" ] || fail kwin-pre
boot_id=$(cat /proc/sys/kernel/random/boot_id)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
outdir=/var/lib/m1892/suspend-tests/$stamp
install -d -m 0700 "$outdir"
"$cellular_acceptance" --timeout 20 >"$outdir/cellular-before.jsonl" ||
	fail cellular-pre
success_before=$(cat /sys/power/suspend_stats/success)
battery_before=$(cat /sys/class/power_supply/qcom-battery/capacity)
aosd_before=$(qcom_count aosd)
cxsd_before=$(qcom_count cxsd)
wifi_failures_before=$(wifi_failure_count)
kernel_failures_before=$(suspend_kernel_failure_count)
systemd_watchdogs_before=$(systemd_watchdog_failure_count)
power_irq_before=$(awk '/pm8941_pwrkey/ {sum=0; for (i=2; i<=9; i++) sum+=$i; print sum}' /proc/interrupts)
rtc_before=$(pmic_rtc_epoch)
{
	echo format=m1892-s2idle-test-v2
	echo boot_id="$boot_id"
	echo success_before="$success_before"
	echo battery_before="$battery_before"
	echo aosd_before="$aosd_before"
	echo cxsd_before="$cxsd_before"
	echo wifi_failures_before="$wifi_failures_before"
	echo kernel_failures_before="$kernel_failures_before"
	echo systemd_watchdogs_before="$systemd_watchdogs_before"
	echo power_irq_before="$power_irq_before"
	echo entry_pmic_rtc_epoch="$rtc_before"
	echo entry_boottime="$(boottime_now)"
	echo entry_uptime="$(cut -d' ' -f1 /proc/uptime)"
	echo entry_epoch_ns="$(date +%s%N)"
} >"$outdir/result"
cp /sys/kernel/debug/wakeup_sources "$outdir/wakeup-sources-before"
sync
echo "M1892_S2IDLE_BEGIN evidence=$outdir"

systemctl suspend

echo resume_epoch_ns="$(date +%s%N)" >>"$outdir/result"
echo resume_boottime="$(boottime_now)" >>"$outdir/result"
echo resume_uptime="$(cut -d' ' -f1 /proc/uptime)" >>"$outdir/result"
rtc_after=$(pmic_rtc_epoch)
echo resume_pmic_rtc_epoch="$rtc_after" >>"$outdir/result"
case "$rtc_before:$rtc_after" in
	*[!0-9:]*|:*) echo pmic_rtc_delta_seconds=unavailable >>"$outdir/result" ;;
	*) echo pmic_rtc_delta_seconds="$((rtc_after - rtc_before))" >>"$outdir/result" ;;
esac
echo suspend_elapsed_seconds=unavailable >>"$outdir/result"
echo suspend_duration_source=external-host-required >>"$outdir/result"
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id" ] || fail rebooted
counter_wait=0
while [ "$(cat /sys/power/suspend_stats/success)" -le "$success_before" ] &&
	[ "$counter_wait" -lt 50 ]; do
	counter_wait=$((counter_wait + 1))
	sleep 0.1
done
success_after=$(cat /sys/power/suspend_stats/success)
[ "$success_after" -gt "$success_before" ] || fail suspend-counter
kernel_failures_after=$(suspend_kernel_failure_count)
systemd_watchdogs_after=$(systemd_watchdog_failure_count)
aosd_after=$(qcom_count aosd)
cxsd_after=$(qcom_count cxsd)
battery_after=$(cat /sys/class/power_supply/qcom-battery/capacity)
wifi_failures_after=$(wifi_failure_count)
{
	echo success_after="$success_after"
	echo battery_after="$battery_after"
	echo aosd_after="$aosd_after"
	echo cxsd_after="$cxsd_after"
	echo wifi_failures_after="$wifi_failures_after"
	echo kernel_failures_after="$kernel_failures_after"
	echo systemd_watchdogs_after="$systemd_watchdogs_after"
} >>"$outdir/result"
[ "$kernel_failures_after" -eq "$kernel_failures_before" ] ||
	fail kernel-failure-after-resume
[ "$systemd_watchdogs_after" -eq "$systemd_watchdogs_before" ] ||
	fail systemd-watchdog-after-resume
[ "$(cat /sys/class/block/sda/device/state)" = running ] || fail ufs-post
[ "$(cat /sys/fs/ext4/sda19/errors_count)" = 0 ] || fail ext4-post
[ "$(pgrep -o -u "$uid" -x kwin_wayland)" = "$kwin_pid" ] || fail kwin-restarted
waited=0
while [ "$(nmcli -g GENERAL.STATE device show wlan0 2>/dev/null || true)" != '100 (connected)' ] &&
	[ "$waited" -lt 90 ]; do
	waited=$((waited + 1))
	sleep 1
done
[ "$waited" -lt 90 ] || fail wifi-resume-timeout
cellular_wait_start=$(cut -d' ' -f1 /proc/uptime)
"$cellular_acceptance" --timeout "$cellular_resume_timeout" \
	>"$outdir/cellular-after.jsonl" || fail cellular-resume-timeout
cellular_wait_end=$(cut -d' ' -f1 /proc/uptime)
wait_ufs_runtime_suspended || fail ufs-runtime-suspend-timeout
ufs_clock_refs_zero || fail ufs-clock-reference

power_irq_after=$(awk '/pm8941_pwrkey/ {sum=0; for (i=2; i<=9; i++) sum+=$i; print sum}' /proc/interrupts)
pm_entry_monotonic=$(last_pm_timestamp 'PM: suspend entry')
pm_exit_monotonic=$(last_pm_timestamp 'PM: suspend exit')
cp /sys/kernel/debug/wakeup_sources "$outdir/wakeup-sources-after"
{
	echo power_irq_after="$power_irq_after"
	echo pm_entry_monotonic="$pm_entry_monotonic"
	echo pm_exit_monotonic="$pm_exit_monotonic"
	echo wifi_wait_seconds="$waited"
	echo cellular_wait_uptime_start="$cellular_wait_start"
	echo cellular_wait_uptime_end="$cellular_wait_end"
	echo suspend_counter_wait_deciseconds="$counter_wait"
	echo result=pass
} >>"$outdir/result"
sync -f "$outdir/result" 2>/dev/null || sync
cat "$outdir/result"
echo M1892_S2IDLE_PASS
