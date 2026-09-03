#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

# Build a local, non-redistributable M1892 firmware tree from the owner's
# official Flyme 8.1.9.0A update package (or its five extracted members).

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
input=${1:-}
output=${2:-}
package_archive=${3:-}
[ -r "$input" ] || {
	echo "usage: $0 FLYME_UPDATE_ZIP_OR_DIRECTORY NEW_OUTPUT [PACKAGE_ARCHIVE]" >&2
	exit 2
}
[ -n "$output" ] || { echo "missing output directory" >&2; exit 2; }
[ ! -e "$output" ] || { echo "output already exists: $output" >&2; exit 1; }
[ -z "$package_archive" ] || [ ! -e "$package_archive" ] || {
	echo "package archive already exists: $package_archive" >&2
	exit 1
}
encoder=${ATH10K_BDENCODER:-}
[ -x "$encoder" ] || {
	echo "set ATH10K_BDENCODER to the pinned qca-swiss-army-knife ath10k-bdencoder" >&2
	exit 1
}
for command in curl debugfs find gzip install mktemp python3 sha256sum tar unzip; do
	command -v "$command" >/dev/null 2>&1 || { echo "missing command: $command" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-flyme-extract.XXXXXX")
cleanup()
{
	find "$work" -depth -delete 2>/dev/null || true
	[ -z "$package_archive" ] || find "$package_archive.tmp" -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

member()
{
	name=$1 destination=$2
	if [ -d "$input" ]; then
		source=$input/$name
		[ -r "$source" ] || source=$input/${name##*/}
		[ -r "$source" ] || { echo "missing input member: $name" >&2; exit 1; }
		cp "$source" "$destination"
	else
		unzip -p "$input" "$name" >"$destination"
	fi
}

member firmware-update/BTFM.bin "$work/BTFM.bin"
member firmware-update/NON-HLOS.bin "$work/NON-HLOS.bin"
member firmware-update/dspso.bin "$work/dspso.bin"
member vendor.new.dat "$work/vendor.new.dat"
member vendor.transfer.list "$work/vendor.transfer.list"

check()
{
	expected=$1 file=$2
	actual=$(sha256sum "$file" | awk '{print $1}')
	[ "$actual" = "$expected" ] || {
		echo "unexpected Flyme member hash: $file: $actual" >&2
		exit 1
	}
}
check 7956dbc763a41ff77fac21e3ee7a15bf198b2ae0560807b63f011c7b9c5d3224 "$work/BTFM.bin"
check 54c47c6c04af04b0d934fc64697e4007a24bf9498afce59af8aa2314c39cfa74 "$work/NON-HLOS.bin"
check 49beb0b495a4ae90375bca3370397fedb70062df9673b3127b707669acf8a4a4 "$work/dspso.bin"
check 8e8e2311bd5e47ef9ffa0ef636073d9600b80c0e2f8ce171905f35892e7a76c5 "$work/vendor.new.dat"
check e828c26707f95b7543627ab242304b6fd5da96992185c7ff6233304c02a4183b "$work/vendor.transfer.list"

python3 "$script_dir/sdat2img.py" "$work/vendor.transfer.list" \
	"$work/vendor.new.dat" "$work/vendor.img"
check b4cb04c82553b2c1c61725d2132fa1d6c95cdf93063b3a02d31e53968638bdd6 "$work/vendor.img"

root=$work/root
install -d "$root/lib/firmware" "$root/usr/share/qcom/sdm845/Meizu/m1892"
python3 "$script_dir/fat16-extract.py" "$work/BTFM.bin" "$root/lib/firmware" \
	/IMAGE/CRBTFW21.TLV=qca/crbtfw21.tlv \
	/IMAGE/CRNV21.BIN=qca/m1892/crnv21.bin

set -- "$work/NON-HLOS.bin" "$root/lib/firmware"
for index in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14; do
	set -- "$@" "/IMAGE/ADSP.B$index=qcom/sdm845/m1892/adsp.b$index"
done
set -- "$@" /IMAGE/ADSP.MDT=qcom/sdm845/m1892/adsp.mdt
for index in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23; do
	set -- "$@" "/IMAGE/SLPI.B$index=qcom/sdm845/Meizu/m1892/slpi.b$index"
done
set -- "$@" /IMAGE/SLPI.MDT=qcom/sdm845/Meizu/m1892/slpi.mdt \
	/IMAGE/SLPIR.JSN=qcom/sdm845/Meizu/m1892/slpir.jsn \
	/IMAGE/SLPIUS.JSN=qcom/sdm845/Meizu/m1892/slpius.jsn \
	/IMAGE/MBA.MBN=qcom/sdm845/m1892/mba.mbn \
	/IMAGE/MODEM.MDT=qcom/sdm845/m1892/modem.mbn \
	/IMAGE/WLANMDSP.MBN=ath10k/WCN3990/hw1.0/wlanmdsp.mbn
for index in 00 01 02 03 04 05 06 07 08 09 10 11 12 13 15 16 17 18 20 21 22 23 24 25 26 27 28; do
	set -- "$@" "/IMAGE/MODEM.B$index=qcom/sdm845/m1892/modem.b$index"
done
for index in 00 01 02 03 04; do
	set -- "$@" "/IMAGE/VENUS.B$index=qcom/venus-5.2/venus.b$index"
done
set -- "$@" /IMAGE/VENUS.MDT=qcom/venus-5.2/venus.mbn
python3 "$script_dir/fat16-extract.py" "$@"

# The stock WLAN.HL.2.0.c10-00089 WLANMDSP asserts in halphy_caldb.c:2993 on
# every active NetworkManager transition. The accepted replacement is the
# redistributable linux-firmware 01387 WLANMDSP paired with the upstream
# 35-entry board database plus this phone model's exact owner-extracted Flyme
# B01 entry. Reproduce that pair here.
upstream_board=$work/upstream-board-2.bin
upstream_wlanmdsp=$work/upstream-wlanmdsp.mbn
curl -fL --retry 3 -o "$upstream_board" \
	https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20260221/ath10k/WCN3990/hw1.0/board-2.bin
curl -fL --retry 3 -o "$upstream_wlanmdsp" \
	https://gitlab.com/kernel-firmware/linux-firmware/-/raw/20260221/ath10k/WCN3990/hw1.0/wlanmdsp.mbn
check 867e1010787764020653812167d93f5952cbbea05f576209d953d8c9322f18aa \
	"$upstream_board"
check 92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2 \
	"$upstream_wlanmdsp"

bdf=$work/bdf
install -d "$bdf"
set -- "$work/NON-HLOS.bin" "$bdf"
for suffix in 102 104 105 106 107 108 109 B01 B04 B07 B09 B0A B0B B0D B0E B0F B14 B15 B30 B31 B32 B33 B34 B35 B36 B37 B38 B3D B3F BIN; do
	set -- "$@" "/IMAGE/BDWLAN.$suffix=BDWLAN.$suffix"
done
python3 "$script_dir/fat16-extract.py" "$@"
python3 "$script_dir/build-m1892-board2.py" --source-dir "$bdf" \
	--encoder "$encoder" \
	--upstream-board "$upstream_board" \
	--output "$root/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin"
check 13633048cd98816d8f2c1cbe8dcd00193f24953d7e52208a51cb51f96617e9b4 \
	"$root/lib/firmware/ath10k/WCN3990/hw1.0/board-2.bin"
install -m 0644 "$upstream_wlanmdsp" \
	"$root/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn"
check 92e1501254e6de78c0f2e2cf091507d488b608d07e53acd14813a82744823ec2 \
	"$root/lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn"

# API-5 feature declaration used with the accepted 01387 WLANMDSP payload.
python3 - "$root/lib/firmware/ath10k/WCN3990/hw1.0/firmware-5.bin" <<'PY'
from pathlib import Path
import sys
Path(sys.argv[1]).write_bytes(bytes.fromhex(
    "5143412d41544831304b00770100000004000000a4e4be5b0200000003000000"
    "40000c77050000000400000004000000060000000400000003000000"
))
PY

dump()
{
	source=$1 destination=$2
	install -d "$(dirname "$destination")"
	debugfs -R "dump -p $source $destination" "$work/vendor.img" >/dev/null 2>&1
	[ -s "$destination" ] || {
		echo "missing or empty vendor payload: $source" >&2
		exit 1
	}
}
dump /firmware/a630_zap.elf "$root/lib/firmware/qcom/sdm845/m1892/a630_zap.mbn"
check c97cd5de29a3a4b5367173295479141e84da37a4a55162a9b6959ea601ff6b9a \
	"$root/lib/firmware/qcom/sdm845/m1892/a630_zap.mbn"
dump /firmware/dw_172hz.bin "$root/lib/firmware/qcom/m1892/dw_172hz.bin"
for file in ipa_fws.b00 ipa_fws.b01 ipa_fws.b02 ipa_fws.b03 ipa_fws.b04 ipa_fws.mdt; do
	dump "/firmware/$file" "$root/lib/firmware/qcom/sdm845/m1892/$file"
done
sdsp_parent=$root/usr/share/qcom/sdm845/Meizu/m1892/dsp
install -d "$sdsp_parent"
debugfs -R "rdump /sdsp $sdsp_parent" "$work/dspso.bin" >/dev/null 2>&1
sensors=$root/usr/share/qcom/sdm845/Meizu/m1892/sensors
install -d "$sensors"
debugfs -R "rdump /etc/sensors/config $sensors" "$work/vendor.img" >/dev/null 2>&1

# Factory calibration/registry is intentionally absent.  It must be imported
# read-only from each phone's own persist partition on first boot.
find "$root" -type f -print | LC_ALL=C sort | while read -r file; do
	printf '%s\t%s\t%s\n' "$(sha256sum "$file" | awk '{print $1}')" \
		"$(stat -c %s "$file")" "${file#$root/}"
done >"$work/FIRMWARE-MANIFEST.tsv"
file_count=$(wc -l <"$work/FIRMWARE-MANIFEST.tsv")
[ "$file_count" -eq 146 ] || { echo "unexpected firmware closure: $file_count" >&2; exit 1; }

if [ -n "$package_archive" ]; then
	install -d "$(dirname "$package_archive")"
	tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --format=gnu \
		-C "$root" -cf - lib usr | gzip -n -9 >"$package_archive.tmp"
	check 381d1873fcbac5d39e16ecd97fe2ccad214465748614cbccc49d21b6727e9133 \
		"$package_archive.tmp"
	mv "$package_archive.tmp" "$package_archive"
fi

mkdir "$output"
cp -a "$root/." "$output/"
install -m 0644 "$work/FIRMWARE-MANIFEST.tsv" "$output/FIRMWARE-MANIFEST.tsv"
cat >"$output/LOCAL-ONLY.txt" <<'EOF'
Generated locally from the owner's official Flyme package.
Contains proprietary firmware. Do not redistribute this directory or an image
that embeds it. Sensor calibration must be imported from this phone's own
persist partition with import-m1892-persist-sensors.sh.
EOF
echo "firmware_files=$file_count output=$output"
[ -z "$package_archive" ] || echo "package_archive=$package_archive"
echo M1892_FLYME_FIRMWARE_EXTRACT_PASS
