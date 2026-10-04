#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
test ! -e "$tree_dir/rootfs-overlay/usr/local/bin/plasma-mobile-initial-start"
! grep -Fq 'QT_QUICK_BACKEND=software' "$tree_dir/scripts/prepare-stage3-rootfs.sh"
grep -Fq 'initialstart_backend=distribution-default-hardware' \
	"$tree_dir/scripts/prepare-stage3-rootfs.sh"
grep -Fq 'unexpected-initialstart-launcher' "$tree_dir/scripts/verify-stage7-persistent-artifacts.sh"
grep -Fq 'command -v plasma-mobile-initial-start' \
	"$tree_dir/rootfs-overlay/usr/libexec/m1892/stage3-session-acceptance"
echo M1892_INITIALSTART_POLICY_TEST_PASS
