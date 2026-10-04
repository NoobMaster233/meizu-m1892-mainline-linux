#!/bin/sh
# SPDX-License-Identifier: MIT
# Run bounded systemd pm_test cycles on an authenticated M1892 manual-suspend candidate.
set -eu

fail() { echo "M1892_PM_TEST_FAIL: $*" >&2; exit 1; }
pm_test=/sys/power/pm_test
suspend_success=/sys/power/suspend_stats/success

[ "$(id -u)" = 0 ] || fail root-required
[ "$(tr -d '\000' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] ||
	fail wrong-hardware
grep -Fxq 'suspend_policy=manual' /etc/m1892-rootfs-identity || fail wrong-policy
[ "$(cat /sys/power/mem_sleep)" = '[s2idle]' ] || fail s2idle-unavailable
[ -r "$pm_test" ] && [ -w "$pm_test" ] || {
	echo M1892_PM_TEST_MATRIX_SKIP reason=kernel-pm-test-unavailable
	exit 0
}
[ -r "$suspend_success" ] || fail suspend-stats-unavailable
[ "$(systemctl is-enabled sleep.target)" != masked ] || fail sleep-target-masked
[ "$(systemctl is-enabled suspend.target)" != masked ] || fail suspend-target-masked
[ "$(systemctl is-enabled hibernate.target)" = masked ] || fail hibernate-target-open
systemctl is-active --quiet m1892-wake-policy.service || fail wake-policy-inactive

boot_id=$(cat /proc/sys/kernel/random/boot_id)
cleanup()
{
	printf 'none\n' >"$pm_test" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

for level in freezer devices platform; do
	for cycle in 1 2 3; do
		printf '%s\n' "$level" >"$pm_test"
		before=$(cat "$suspend_success")
		echo "M1892_PM_TEST_BEGIN level=$level cycle=$cycle before=$before"
		systemctl suspend
		after=$(cat "$suspend_success")
		[ "$after" -gt "$before" ] || fail "counter:$level:$cycle:$before:$after"
		[ "$(cat /proc/sys/kernel/random/boot_id)" = "$boot_id" ] ||
			fail "rebooted:$level:$cycle"
		[ "$(cat /sys/class/block/sda/device/state)" = running ] ||
			fail "ufs:$level:$cycle"
		[ "$(cat /sys/fs/ext4/sda19/errors_count)" = 0 ] ||
			fail "ext4:$level:$cycle"
		echo "M1892_PM_TEST_PASS level=$level cycle=$cycle after=$after"
	done
done

cleanup
trap - EXIT HUP INT TERM
echo M1892_PM_TEST_MATRIX_PASS
