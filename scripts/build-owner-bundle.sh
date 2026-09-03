#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

flyme=${1:-}
owner_public_key=${2:-}
output=${3:-}
release_tag=${M1892_RELEASE_TAG:-2026.09-developer-preview.17}
fail() { echo "M1892_OWNER_BUNDLE_FAIL: $*" >&2; exit 1; }
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
container_user=${M1892_CONTAINER_BUILD_USER:-}
container_home=${M1892_CONTAINER_BUILD_HOME:-}
apk_stage=
partial_output=
cleanup()
{
	[ -z "$apk_stage" ] || find "$apk_stage" -depth -delete 2>/dev/null || true
	[ -z "$partial_output" ] || find "$partial_output" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ "$flyme" = --container-selftest ]; then
	[ "$(id -u)" -eq 0 ] || fail container-selftest-root
	[ -n "$container_user" ] && [ -n "$container_home" ] ||
		fail container-selftest-user-config
	command -v su-exec >/dev/null 2>&1 || fail container-selftest-su-exec
	id "$container_user" >/dev/null 2>&1 || fail container-selftest-user
	[ "$(su-exec "$container_user" id -u)" -ne 0 ] ||
		fail container-selftest-privilege-drop
	[ -d "$container_home" ] && su-exec "$container_user" test -w "$container_home" ||
		fail container-selftest-home
	echo M1892_OWNER_CONTAINER_SELFTEST_PASS
	exit 0
fi

[ -f "$flyme" ] || fail missing-flyme-zip
[ -f "$owner_public_key" ] || fail missing-owner-public-key
[ -n "$output" ] || fail missing-output-directory
for command in chmod cp curl find git id mkdir mktemp mv sha256sum zstd; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
output_parent=$(CDPATH='' cd -- "$(dirname -- "$output")" && pwd)
final_output=$output_parent/$(basename -- "$output")
[ ! -e "$final_output" ] || fail output-exists
partial_output=$final_output.partial.$$
[ ! -e "$partial_output" ] || fail partial-output-exists
mkdir "$partial_output"
output=$partial_output
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/$release_tag

for asset in m1892-mainline-base.raw.zst m1892-mainline-base.raw.zst.sha256 \
	m1892-mainline-boot.img m1892-mainline-boot.img.sha256 \
	m1892-public-kernel.tar.gz m1892-public-kernel.tar.gz.sha256 \
	m1892-telephony-audio-runtime.tar.gz \
	m1892-telephony-audio-runtime.tar.gz.sha256; do
	curl -fL --retry 3 -o "$output/$asset" "$release/$asset"
done
(cd "$output" && sha256sum -c m1892-mainline-base.raw.zst.sha256)
(cd "$output" && sha256sum -c m1892-mainline-boot.img.sha256)
(cd "$output" && sha256sum -c m1892-public-kernel.tar.gz.sha256)
(cd "$output" && sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256)
"$script_dir/verify-m1892-telephony-audio-runtime.sh" \
	"$output/m1892-telephony-audio-runtime.tar.gz"
zstd -d --long=31 --sparse "$output/m1892-mainline-base.raw.zst" \
	-o "$output/m1892-mainline-base.raw"
printf '%s  %s\n' \
	dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
	"$output/m1892-mainline-base.raw" | sha256sum -c -

git clone https://github.com/qca/qca-swiss-army-knife.git \
	"$output/qca-swiss-army-knife"
git -C "$output/qca-swiss-army-knife" checkout \
	34fa4d6bd6641c79e6a6384816314fbbcd5a23cc
ATH10K_BDENCODER=$output/qca-swiss-army-knife/tools/scripts/ath10k/ath10k-bdencoder
export ATH10K_BDENCODER
"$script_dir/extract-flyme-firmware.sh" "$flyme" \
	"$output/local-firmware" "$output/m1892-firmware-runtime-20260831.tar.gz"
firmware_apk=$output/firmware-meizu-m1892-20260831-r0.apk
if [ "$(id -u)" -eq 0 ]; then
	[ -n "$container_user" ] && [ -n "$container_home" ] ||
		fail root-requires-container-build-user
	command -v su-exec >/dev/null 2>&1 || fail missing-command:su-exec
	id "$container_user" >/dev/null 2>&1 || fail container-build-user
	apk_stage=$(mktemp -d "${TMPDIR:-/tmp}/m1892-owner-apk.XXXXXX")
	chown "$container_user" "$apk_stage"
	su-exec "$container_user" env HOME="$container_home" \
		ATH10K_BDENCODER="$ATH10K_BDENCODER" \
		"$script_dir/build-local-firmware-apk.sh" \
		"$output/m1892-firmware-runtime-20260831.tar.gz" \
		"$apk_stage/firmware-meizu-m1892-20260831-r0.apk"
	mv "$apk_stage/firmware-meizu-m1892-20260831-r0.apk" "$firmware_apk"
else
	"$script_dir/build-local-firmware-apk.sh" \
		"$output/m1892-firmware-runtime-20260831.tar.gz" "$firmware_apk"
fi
"$script_dir/download-runtime-apks.sh" "$output/alpine-rmtfs-1.3-r0-aarch64"

M1892_ROOT_AUTHORIZED_KEYS_FILE=$owner_public_key \
	M1892_TELEPHONY_AUDIO_ARCHIVE=$output/m1892-telephony-audio-runtime.tar.gz \
	"$script_dir/make-local-firmware-image.sh" \
	"$output/m1892-mainline-base.raw" \
	"$firmware_apk" \
	"$output/alpine-rmtfs-1.3-r0-aarch64" \
	"$output/m1892-public-kernel.tar.gz" \
	"$output/m1892-userdata.raw"
M1892_ROOT_AUTHORIZED_KEYS_FILE=$owner_public_key \
	M1892_TELEPHONY_AUDIO_ARCHIVE=$output/m1892-telephony-audio-runtime.tar.gz \
	"$script_dir/verify-local-firmware-image.sh" \
	"$output/m1892-userdata.raw" \
	"$firmware_apk" \
	"$output/alpine-rmtfs-1.3-r0-aarch64" \
	"$output/m1892-public-kernel.tar.gz"
M1892_FIRMWARE_MODE=complete \
	M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE=$owner_public_key \
	"$script_dir/verify-fresh-image.sh" "$output/m1892-userdata.raw"
"$script_dir/img2fullsimg.py" "$output/m1892-userdata.raw" \
	"$output/m1892-userdata.sparse.img"
"$script_dir/img2fullsimg.py" --verify-against \
	"$output/m1892-userdata.sparse.img" "$output/m1892-userdata.raw"
(cd "$output" && \
	sha256sum m1892-userdata.sparse.img >m1892-userdata.sparse.img.sha256 && \
	sha256sum -c m1892-userdata.sparse.img.sha256 && \
	sha256sum m1892-userdata.raw \
		m1892-userdata.sparse.img >m1892-owner-images.sha256)

# The recommended container path starts in an otherwise empty owner directory.
# Export the audited host-side flashing helper together with its sibling sparse
# parser so that the user never has to guess a branch or fetch an unpinned script.
mkdir "$output/tools"
cp "$script_dir/flash-m1892.sh" "$script_dir/img2fullsimg.py" "$output/tools/"
chmod 0755 "$output/tools/flash-m1892.sh" "$output/tools/img2fullsimg.py"
(cd "$output/tools" && \
	sha256sum flash-m1892.sh img2fullsimg.py >M1892-FLASH-TOOLS.sha256 && \
	sha256sum -c M1892-FLASH-TOOLS.sha256)

mv "$output" "$final_output"
partial_output=
echo "output=$final_output"
echo M1892_OWNER_BUNDLE_PASS
