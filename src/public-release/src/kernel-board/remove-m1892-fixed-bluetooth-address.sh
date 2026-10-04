#!/bin/sh
set -eu

# DT overlays cannot encode /delete-property/ against a live target node.
# Apply the publication-safe transformation directly to a compiled M1892 DTB.

input=${1:-}
output=${2:-}
node=/soc@0/geniqup@8c0000/serial@898000/bluetooth

[ -r "$input" ] || { echo "missing input DTB: $input" >&2; exit 2; }
[ -n "$output" ] || { echo "missing output DTB" >&2; exit 2; }
command -v fdtget >/dev/null 2>&1
command -v fdtput >/dev/null 2>&1

cp "$input" "$output"
fdtget "$output" "$node" local-bd-address >/dev/null
fdtput -d "$output" "$node" local-bd-address
if fdtget "$output" "$node" local-bd-address >/dev/null 2>&1; then
	echo "fixed Bluetooth address remains" >&2
	exit 1
fi
echo M1892_GENERIC_BLUETOOTH_DTB_PASS
