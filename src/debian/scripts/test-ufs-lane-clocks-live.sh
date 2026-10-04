#!/bin/sh
# SPDX-License-Identifier: MIT
# Verify that Qualcomm UFS clock references return to zero after one I/O cycle.
set -eu

fail() { echo "M1892_UFS_CLOCK_FAIL: $*" >&2; exit 1; }
host=/sys/bus/platform/devices/1d84000.ufshc
lun=/sys/class/scsi_host/host0/device
summary=/sys/kernel/debug/clk/clk_summary

wait_suspended()
{
	waited=0
	while { [ "$(cat "$host/power/runtime_status")" != suspended ] ||
		[ "$(cat "$lun/power/runtime_status")" != suspended ]; } &&
		[ "$waited" -lt 300 ]; do
		waited=$((waited + 1))
		sleep 0.1
	done
	[ "$waited" -lt 300 ] || fail runtime-suspend-timeout
}

clock_counts()
{
	awk -v name="$1" '$1 == name {print $2 ":" $3; found++}
		END {if (found != 1) exit 1}' "$summary"
}

[ "$(id -u)" = 0 ] || fail root-required
[ "$(tr -d '\000' </sys/firmware/devicetree/base/model)" = 'Meizu 16th Plus (M1892)' ] ||
	fail wrong-hardware
[ -r "$summary" ] || fail clk-summary-unavailable
[ -d "$host" ] && [ -d "$lun" ] || fail ufs-runtime-path
[ "$(cat /sys/fs/ext4/sda19/errors_count)" = 0 ] || fail ext4-pre

clocks='gcc_ufs_phy_tx_symbol_0_clk
gcc_ufs_phy_rx_symbol_0_clk
gcc_ufs_phy_rx_symbol_1_clk
gcc_ufs_phy_ahb_clk
gcc_ufs_phy_ice_core_clk
gcc_ufs_phy_unipro_core_clk
gcc_aggre_ufs_phy_axi_clk
gcc_ufs_phy_axi_clk'

wait_suspended
echo format=m1892-ufs-lane-clock-test-v1
for clock in $clocks; do
	counts=$(clock_counts "$clock") || fail "clock-absent:$clock"
	echo "before_$clock=$counts"
done

dd if=/dev/sda of=/dev/null bs=4096 count=1 iflag=direct status=none
wait_suspended
[ "$(cat /sys/fs/ext4/sda19/errors_count)" = 0 ] || fail ext4-post
for clock in $clocks; do
	counts=$(clock_counts "$clock") || fail "clock-absent:$clock"
	echo "after_$clock=$counts"
	[ "$counts" = 0:0 ] || fail "unbalanced:$clock:$counts"
done

echo M1892_UFS_CLOCK_PASS
