#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

output=${1:-}
[ -n "$output" ] || { echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 2; }
[ ! -e "$output" ] || { echo "output already exists: $output" >&2; exit 1; }
for command in curl install sha256sum; do
	command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }
done

tag=20260221
base=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$tag/qcom
destination=$output/lib/firmware/qcom
install -d "$destination"
fetch()
{
	name=$1 expected=$2
	curl -L --fail --output "$destination/$name.tmp" "$base/$name"
	actual=$(sha256sum "$destination/$name.tmp" | awk '{print $1}')
	[ "$actual" = "$expected" ] || {
		echo "unexpected upstream firmware hash: $name: $actual" >&2
		exit 1
	}
	mv "$destination/$name.tmp" "$destination/$name"
}
fetch a630_gmu.bin da8d9b1b1f5c1a0b311f32567093b4828f3c80031dd8435f91ac13c664e173a6
fetch a630_sqe.fw 1c21b527d9183487cc550dabbb3f43e555df5a977a461934fc61f0635a9aa90c

echo "linux_firmware_tag=$tag"
sha256sum "$destination/a630_gmu.bin" "$destination/a630_sqe.fw"
echo M1892_OPEN_GPU_FIRMWARE_FETCH_PASS
