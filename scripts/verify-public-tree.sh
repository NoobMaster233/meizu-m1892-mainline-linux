#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

root=${1:-.}
[ -d "$root" ] || { echo "not a directory: $root" >&2; exit 2; }
root=$(CDPATH='' cd -- "$root" && pwd)
fail() { echo "M1892_PUBLIC_TREE_FAIL: $*" >&2; exit 1; }

test -r "$root/README.md" || fail missing-readme
test -r "$root/README_EN.md" || fail missing-english-readme
test -r "$root/LICENSE" || fail missing-repository-license-notice
test -r "$root/LICENSES.md" || fail missing-licenses
for pair in QUICK_START INSTALL BUILD ACTIONS FIRMWARE KNOWN_ISSUES LICENSES PUBLICATION_STATUS; do
	test -r "$root/$pair.md" || fail "missing-chinese-document:$pair"
	test -r "$root/${pair}_EN.md" || fail "missing-english-document:$pair"
	grep -Fq "${pair}_EN.md" "$root/$pair.md" || fail "missing-english-switch:$pair"
	grep -Fq "${pair}.md" "$root/${pair}_EN.md" || fail "missing-chinese-switch:$pair"
done
for workflow in public-contract.yml build-public-components.yml publish-owner-builder.yml; do
	test -r "$root/.github/workflows/$workflow" || fail "missing-workflow:$workflow"
done
test -r "$root/docker/owner-builder.Dockerfile" || fail missing-owner-builder-dockerfile
test -r "$root/.dockerignore" || fail missing-dockerignore
grep -Fxq '**' "$root/.dockerignore" || fail dockerignore-not-deny-by-default
grep -Fq 'FROM alpine:edge@sha256:020dfcbaaf4cc1078bf2d9c7ba31a8466e334061dcd2f248001d68f79e52c000' \
	"$root/docker/owner-builder.Dockerfile" || fail owner-builder-base-not-pinned
grep -Eq '^[[:space:]]*findutils git gzip kmod ' \
	"$root/docker/owner-builder.Dockerfile" || fail owner-builder-kmod-missing
grep -Fq 'ARG M1892_RELEASE_TAG=2026.09-developer-preview.17' \
	"$root/docker/owner-builder.Dockerfile" || fail stale-owner-builder-release-tag
grep -Fq 'default: 2026.09-developer-preview.17' \
	"$root/.github/workflows/publish-owner-builder.yml" ||
	fail stale-owner-builder-workflow-release-tag
test -x "$root/scripts/build-owner-bundle.sh" || fail missing-owner-bundle-helper
grep -Fq 'permissions:' "$root/.github/workflows/public-contract.yml" ||
	fail workflow-permissions-missing
grep -Fq 'packages: write' "$root/.github/workflows/publish-owner-builder.yml" ||
	fail builder-package-permission-missing
grep -Fq 'contents: write' "$root/.github/workflows/publish-owner-builder.yml" ||
	fail builder-release-permission-missing
grep -Fq 'gh release upload "$RELEASE_TAG" m1892-owner-builder.digest' \
	"$root/.github/workflows/publish-owner-builder.yml" ||
	fail builder-digest-release-upload-missing
grep -Fq 'M1892_FRESH_IMAGE_VERIFY_PASS' "$root/ACTIONS.md" ||
	fail actions-fresh-verifier-contract-missing
grep -Fq 'm1892-owner-builder.digest' "$root/ACTIONS.md" ||
	fail actions-owner-builder-digest-missing
grep -Fq 'org.opencontainers.image.revision' \
	"$root/.github/workflows/publish-owner-builder.yml" ||
	fail owner-builder-revision-guard-missing
grep -Fq 'Verify draft Release contract before publishing' \
	"$root/.github/workflows/publish-owner-builder.yml" ||
	fail owner-builder-draft-preflight-missing
grep -Fq 'm1892-owner-builder.digest' \
	"$root/.github/workflows/publish-owner-builder.yml" ||
	fail owner-builder-digest-artifact-missing
grep -Fq 'M1892_DAILY_HEALTH_OK' "$root/QUICK_START.md" ||
	fail first-boot-health-acceptance-missing
grep -Fq 'RELEASE_ID="2026.09-developer-preview.17"' \
	"$root/src/runtime-inputs/userspace/daily/m1892-release" ||
	fail public-release-identity-missing
if grep -Eq 'm1892-mainline-daily|[Rr][0-9]{1,4}' \
	"$root/src/runtime-inputs/userspace/daily/m1892-release"; then
	fail internal-release-identity-leaked
fi
test -r "$root/RELEASE_NOTES.md" || fail missing-chinese-release-notes
test -r "$root/RELEASE_NOTES_EN.md" || fail missing-english-release-notes
grep -Fq 'RELEASE_NOTES_EN.md' "$root/RELEASE_NOTES.md" ||
	fail missing-release-notes-english-switch
grep -Fq 'RELEASE_NOTES.md' "$root/RELEASE_NOTES_EN.md" ||
	fail missing-release-notes-chinese-switch
for internal_document in RELEASE_ENGINEERING.md RELEASE_ENGINEERING_EN.md \
	HISTORICAL_REVISION_COVERAGE.tsv RELEASE_FEATURE_CONTRACT.tsv; do
	test ! -e "$root/$internal_document" ||
		fail "maintainer-document-exported:$internal_document"
done
# Public prose describes the current product contract. Source compatibility
# revision tokens may remain in filenames, never in user-facing Markdown.
if grep -RIlE --include='*.md' \
	'(^|[^[:alnum:]_])[Rr][0-9]{2,4}([^[:alnum:]_]|$)' "$root" 2>/dev/null |
	grep -q .; then
	fail internal-revision-token-in-public-documentation
fi
if grep -RIE \
	'M1892_R[0-9]|release=.*daily|title[[:space:]]*=.*R[0-9]|desc[[:space:]]*=.*R[0-9]|(^|[[:space:]])revision=r[0-9]' \
	"$root/src/boot" "$root/src/edk2" "$root/src/rootfs/fresh-overlay" \
	"$root/src/runtime-inputs" "$root/src/userspace" >/dev/null 2>&1; then
	fail internal-revision-token-in-shipped-content
fi
if grep -RIlE --include='*.md' '(userdata[[:space:]]+[0-9]+/[0-9]+|[0-9]+/[0-9]+[[:space:]]+userdata)' \
	"$root" 2>/dev/null | grep -q .; then
	fail stale-fixed-fastboot-chunk-count-in-public-documentation
fi
for license in MIT GPL-2.0 GPL-3.0 LGPL-2.1 BSD-3-Clause BSD-2-Clause-Patent; do
	test -s "$root/licenses/$license.txt" || fail "missing-license-text:$license"
done
test -r "$root/config/build-options.env.example" || fail missing-build-options
# Public users need current source, checks and support status. The explicit
# path gates below retain the release's source-completeness check while legacy
# compatibility filenames remain an implementation detail.
for path in \
	scripts/build-local-firmware-apk.sh \
	scripts/download-runtime-apks.sh \
	scripts/verify-fresh-image.sh \
	scripts/build-public-edk2-loader.sh \
	scripts/materialize-public-kernel.sh \
	scripts/build-public-kernel.sh \
	scripts/package-public-kernel.sh \
	scripts/build-m1892-telephony-audio-runtime.sh \
	scripts/verify-m1892-telephony-audio-runtime.sh \
	scripts/verify-m1892-telephony-audio-source.sh \
	scripts/verify-public-kernel.sh \
	scripts/verify-public-boot-image.sh \
	scripts/make-public-recovery-image.sh \
	scripts/verify-public-recovery-image.sh \
	src/boot/init-r537-public-root \
	src/boot/reboot-fastboot.c \
	src/userspace/daily/m1892-rmtfs-shadow \
	src/userspace/daily/m1892-rmtfs-shadow.openrc \
	src/userspace/daily/m1892-radio-bootstrap \
	src/userspace/daily/m1892-radio-bootstrap.openrc \
	src/userspace/daily/m1892-cellular-prepare \
	src/userspace/daily/m1892-cellular-prepare.openrc \
	src/userspace/daily/m1892-daily-health \
	src/userspace/daily/m1892-docker-selftest \
	src/rootfs/finalize-m1892-r6-fresh-image.sh \
	src/rootfs/verify-m1892-r6-fresh-image.sh \
	src/rootfs/fresh-overlay-metadata.tsv \
	src/phoc/userspace/phosh/build-phoc-r523.sh \
	src/phoc/patches/0001-phoc-input-method-fix-keyboard-grab-destroy-null.patch \
	src/rootfs/fresh-overlay/etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop \
	src/rootfs/fresh-overlay/etc/skel/.local/share/applications/sm.puri.OSK0.desktop \
	src/runtime/SOURCE_FILES.tsv \
	src/runtime/ARTIFACTS.sha256 \
	src/runtime/install-m1892-r6-userspace-overlay.sh \
	src/runtime/verify-m1892-r6-userspace-overlay-live.sh \
	src/runtime-inputs/userspace/daily/m1892-suspend \
	src/runtime-inputs/userspace/daily/m1892-safe-restart \
	src/runtime-inputs/userspace/daily/47-m1892-power-actions.rules \
	src/runtime-inputs/m1892-userspace/openrc/m1892-speaker \
	src/runtime-inputs/userspace/telephony/callaudiod-pulse17-split-profile.patch \
	src/runtime-inputs/userspace/telephony/org.mobian_project.CallAudio.service \
	src/runtime-inputs/userspace/telephony/81voltd-m1892-ip-config.patch \
	src/runtime-inputs/userspace/telephony/m1892-81voltd.openrc \
	src/runtime-inputs/userspace/telephony/qcom-imsd-m1892.patch \
	src/runtime-inputs/userspace/telephony/modemmanager-qmi-sms-over-ims.patch \
	src/runtime-inputs/userspace/telephony/m1892-qcom-imsd \
	src/runtime-inputs/userspace/telephony/m1892-qcom-imsd.openrc \
	src/runtime-inputs/userspace/bluetooth/bluetooth.openrc \
	src/runtime-inputs/userspace/bluetooth/m1892-bluetooth-identity \
	src/runtime-inputs/userspace/bluetooth/m1892-bluetooth-selftest \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced.conf \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced.openrc \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced-m1892.c; do
	test -r "$root/$path" || fail "missing-radio-source:$path"
done
for obsolete in \
	src/userspace/bluetooth/bluetooth-r247.openrc \
	src/userspace/bluetooth/m1892-bluetooth-identity-r247 \
	src/userspace/bluetooth/m1892-bluetooth-selftest-r247; do
	test ! -e "$root/$obsolete" || fail "obsolete-bluetooth-source:$obsolete"
done

grep -Fq 'm1892-mainline-base.raw.zst.sha256' "$root/QUICK_START.md" ||
	fail quick-start-compressed-sidecar
grep -Fq 'm1892-public-kernel.tar.gz.sha256' "$root/QUICK_START.md" ||
	fail quick-start-kernel-bundle-sidecar
grep -Fq 'm1892-public-kernel.tar.gz' "$root/scripts/build-owner-bundle.sh" ||
	fail owner-builder-kernel-bundle-missing
grep -Fq 'm1892-userdata.sparse.img.sha256' "$root/scripts/build-owner-bundle.sh" ||
	fail owner-builder-sparse-sidecar-missing
grep -Fq 'sha256sum -c m1892-userdata.sparse.img.sha256' \
	"$root/scripts/build-owner-bundle.sh" ||
	fail owner-builder-sparse-sidecar-check-missing
grep -Fq './scripts/package-public-kernel.sh' \
	"$root/.github/workflows/build-public-components.yml" ||
	fail workflow-kernel-packager-missing
kernel_manifest_line=$(grep -n '^cat >"\$output/M1892-KERNEL-BUILD-MANIFEST.txt"' \
	"$root/scripts/build-public-kernel.sh" | cut -d: -f1)
kernel_verify_line=$(grep -n '^"\$(dirname -- "\$0")/verify-public-kernel.sh"' \
	"$root/scripts/build-public-kernel.sh" | cut -d: -f1)
[ -n "$kernel_manifest_line" ] && [ -n "$kernel_verify_line" ] &&
	[ "$kernel_verify_line" -gt "$kernel_manifest_line" ] ||
	fail kernel-verifier-runs-before-manifest
grep -Fq 'build-m1892-telephony-audio-runtime.sh' \
	"$root/.github/workflows/build-public-components.yml" ||
	fail workflow-telephony-audio-builder-missing
grep -Fq 'm1892-telephony-audio-source.tar.gz' \
	"$root/.github/workflows/build-public-components.yml" ||
	fail workflow-telephony-source-artifact-missing
grep -Fq 'verify-m1892-telephony-audio-source.sh' \
	"$root/.github/workflows/build-public-components.yml" ||
	fail workflow-telephony-source-verifier-missing
for dependency in alsa-lib-dev build-base elogind-dev libmbim-dev libqmi-dev \
	linux-headers modemmanager-dev polkit-dev pulseaudio-dev python3 qrtr-dev \
	samurai; do
	grep -Fq "$dependency" "$root/.github/workflows/build-public-components.yml" ||
		fail "workflow-telephony-dependency-missing:$dependency"
done
grep -Fq 'pyosmocom_sha256=8129e17744b65eada285baf5ddab18a8eb52d704ca7aeeb53a83783cdfa3c3c8' \
	"$root/scripts/build-m1892-telephony-audio-runtime.sh" ||
	fail telephony-pyosmocom-pin-missing
grep -Fq 'statemachine_sha256=0ed53846802c17037fcb2a92323f4bc0c833290fa9d17a3587c50886c1541e62' \
	"$root/scripts/build-m1892-telephony-audio-runtime.sh" ||
	fail telephony-statemachine-pin-missing
grep -Fq 'm1892-qcom-imsd q6voiced docker' \
	"$root/src/runtime-inputs/userspace/daily/m1892-daily-health" ||
	fail daily-health-telephony-services-missing
grep -Fq 'm1892-telephony-audio-runtime.tar.gz' \
	"$root/scripts/build-owner-bundle.sh" ||
	fail owner-builder-telephony-audio-runtime-missing
grep -Fq 'M1892-integration/LICENSE' \
	"$root/scripts/verify-m1892-telephony-audio-runtime.sh" ||
	fail telephony-integration-license-missing
grep -Fq 'M1892_TELEPHONY_AUDIO_ARCHIVE' \
	"$root/scripts/make-local-firmware-image.sh" ||
	fail local-image-telephony-audio-runtime-missing
for runtime in m1892-power m1892-power.openrc m1892-daily-health m1892-docker-selftest; do
	grep -Fq "userspace/daily/$runtime" \
		"$root/scripts/make-local-firmware-image.sh" ||
		fail "owner-runtime-overlay-missing:$runtime"
done
for runtime in \
	userspace/telephony/48-m1892-telephony.rules \
	userspace/bluetooth/m1892-bluetooth-identity \
	userspace/bluetooth/m1892-bluetooth-selftest; do
	grep -F "$runtime" "$root/src/runtime/SOURCE_FILES.tsv" |
		grep -Fq 'owner-overlay' || fail "owner-overlay-contract:$runtime"
done
for module in \
	drivers/firmware/cirrus/cs_dsp.ko \
	sound/soc/codecs/snd-soc-wm-adsp.ko \
	sound/soc/codecs/snd-soc-cs35l41-lib.ko \
	sound/soc/codecs/snd-soc-cs35l41.ko \
	sound/soc/codecs/snd-soc-cs35l41-spi.ko \
	sound/soc/qcom/snd-soc-sdm845.ko; do
	grep -Fq "$module" "$root/scripts/package-public-kernel.sh" ||
		fail "kernel-packager-speaker-module:$module"
done
grep -Fq 'dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46' \
	"$root/QUICK_START.md" || fail quick-start-raw-hash
grep -Fq 'fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad' \
	"$root/README.md" || fail readme-compressed-base-hash
grep -Fq '7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526' \
	"$root/README.md" || fail readme-boot-hash
for boot_contract in make-public-boot-image.sh verify-public-boot-image.sh; do
	grep -Fq '4ea1ce45ec3a8741ca8984a4e1f0e6104a904a63d32da34f9c0c3e452ff87441' \
		"$root/scripts/$boot_contract" || fail "stale-edk2-patch-contract:$boot_contract"
done
grep -Fq '9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c' \
	"$root/README.md" || fail readme-kernel-bundle-hash
grep -Fq '05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b' \
	"$root/README.md" || fail readme-telephony-bundle-hash
grep -Fq '31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf' \
	"$root/README.md" || fail readme-telephony-runtime-hash
grep -Fq '4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843' \
	"$root/README.md" || fail readme-telephony-source-hash
for hash in \
	a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4 \
	5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769 \
	09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7; do
	grep -Fq "$hash" "$root/README.md" || fail "readme-rmtfs-hash:$hash"
done
grep -Fq 'test -s "$OWNER_PUBLIC_KEY"' "$root/QUICK_START.md" ||
	fail quick-start-does-not-require-existing-public-key
grep -Fq 'e2fsprogs e2fsprogs-extra' "$root/QUICK_START.md" ||
	fail quick-start-e2fsprogs-packages-missing
grep -Fq "printf '%s\\n' 1.47.4" "$root/QUICK_START.md" ||
	fail quick-start-e2fsprogs-minimum-version-missing
grep -Fq 'findutils git gzip kmod ' "$root/QUICK_START.md" ||
	fail quick-start-kmod-missing
grep -Fq 'out/tools/flash-m1892.sh' "$root/QUICK_START.md" ||
	fail quick-start-container-flash-helper-missing
grep -Fq 'cp "$script_dir/flash-m1892.sh" "$script_dir/img2fullsimg.py"' \
	"$root/scripts/build-owner-bundle.sh" || fail owner-builder-flash-tools-missing
grep -Fq 'zstd -d --long=31 --sparse' "$root/scripts/build-owner-bundle.sh" ||
	fail owner-builder-zstd-long-window-missing
grep -Fq 'zstd -d --long=31' "$root/QUICK_START.md" ||
	fail quick-start-zstd-long-window-missing
for guide in QUICK_START.md QUICK_START_EN.md INSTALL.md INSTALL_EN.md \
	FIRMWARE.md FIRMWARE_EN.md; do
	grep -Fq 'zstd -d --long=31' "$root/$guide" ||
		fail "document-zstd-long-window-missing:$guide"
done
for radio_file in m1892-rmtfs-shadow m1892-rmtfs-shadow.openrc \
	m1892-radio-bootstrap m1892-radio-bootstrap.openrc; do
	cmp -s "$root/src/userspace/daily/$radio_file" \
		"$root/src/runtime-inputs/userspace/daily/$radio_file" ||
		fail "duplicate-radio-runtime-drift:$radio_file"
done
grep -Fq 'base-radio-runtime-semantics' "$root/scripts/make-local-firmware-image.sh" ||
	fail owner-builder-radio-semantic-gate-missing
grep -Fq 'write $radio_bootstrap /usr/local/sbin/m1892-radio-bootstrap' \
	"$root/scripts/make-local-firmware-image.sh" ||
	fail owner-builder-radio-current-overlay-missing
grep -Fq 'git checkout 2026.09-developer-preview.17' "$root/QUICK_START.md" ||
	fail quick-start-release-tag-not-pinned
grep -Fq 'M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE="$M1892_ROOT_AUTHORIZED_KEYS_FILE"' \
	"$root/INSTALL.md" || fail install-owner-key-verification-missing
grep -Fq 'M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE="$M1892_ROOT_AUTHORIZED_KEYS_FILE"' \
	"$root/QUICK_START.md" || fail quick-start-owner-key-verification-missing
grep -Fq 'e2fsck -V' "$root/QUICK_START.md" ||
	fail quick-start-e2fsprogs-version-check-missing
grep -Fq 'docker` 组' "$root/QUICK_START.md" ||
	fail quick-start-does-not-disclose-docker-root-equivalence
grep -Fq 'apk add flatpak' "$root/README.md" ||
	fail readme-pods-missing-flatpak-prerequisite
if grep -RIl --exclude=verify-public-tree.sh \
	'sha256sum -c m1892-mainline-base.raw.sha256' \
	"$root" 2>/dev/null | grep -q .; then
	fail nonexistent-base-raw-sidecar-in-documentation
fi
grep -Fq '474dbb8e25e8e38f9e1880b5310e830c51a71732bdcf0264b31b1bac092173ab5eea3f2ad599900e2bef1d5f73a04c456c36521edfdce5fd5c2cca670f0dd3dd' \
	"$root/FIRMWARE.md" || fail current-firmware-archive-hash
allowlist=$root/src/kernel/K1_SOURCE_ALLOWLIST.sha256
map=$root/src/kernel/K1_PACKAGE_MAP.tsv
test -r "$allowlist" || fail missing-kernel-allowlist
test -r "$map" || fail missing-kernel-package-map
while read -r expected source; do
	case $expected in \#*|'') continue ;; esac
	input=$root/src/kernel-inputs/$source
	test -r "$input" || fail "missing-kernel-input:$source"
	actual=$(sha256sum "$input" | awk '{print $1}')
	test "$actual" = "$expected" || fail "kernel-input-hash:$source"
done <"$allowlist"
awk '!/^#/ && NF {print $2}' "$allowlist" | LC_ALL=C sort >"${TMPDIR:-/tmp}/m1892-tree-allow.$$"
awk -F '\t' '!/^#/ && NF {print $2}' "$map" | LC_ALL=C sort >"${TMPDIR:-/tmp}/m1892-tree-map.$$"
if comm -3 "${TMPDIR:-/tmp}/m1892-tree-allow.$$" "${TMPDIR:-/tmp}/m1892-tree-map.$$" | grep -q .; then
	rm -f "${TMPDIR:-/tmp}/m1892-tree-allow.$$" "${TMPDIR:-/tmp}/m1892-tree-map.$$"
	fail kernel-map-allowlist-mismatch
fi
rm -f "${TMPDIR:-/tmp}/m1892-tree-allow.$$" "${TMPDIR:-/tmp}/m1892-tree-map.$$"
for path in src/edk2/patches/edk2-r540-direct-simpleinit-diagnostic.patch \
	src/edk2/patches/simpleinit-direct-failure-hold.patch \
	src/edk2/patches/simpleinit-fdt-initrd-address.patch \
	src/edk2/simpleinit.static.uefi-r541-public-inner-diag.cfg; do
	test -r "$root/$path" || fail "missing-edk2-source:$path"
done
fcitx_override=$root/src/rootfs/fresh-overlay/etc/skel/.config/autostart/org.fcitx.Fcitx5.desktop
grep -qx 'Hidden=true' "$fcitx_override" || fail fcitx-autostart-hidden
grep -qx 'X-GNOME-Autostart-enabled=false' "$fcitx_override" || fail fcitx-autostart-disabled
phosh_override=$root/src/rootfs/fresh-overlay/etc/skel/.config/autostart/mobi.phosh.Shell.desktop
grep -qx 'Exec=/usr/libexec/phosh -U' "$phosh_override" || fail phosh-unlocked-command
osk_desktop=$root/src/rootfs/fresh-overlay/etc/skel/.local/share/applications/sm.puri.OSK0.desktop
grep -qx 'Exec=/usr/bin/phosh-osk-stevia --allow-replacement' "$osk_desktop" || fail osk-command
test -z "$(find "$root" -path "$root/.git" -prune -o -type f -name '*r235*' -print -quit)" || fail custom-osk-bridge-present
test -z "$(find "$root" -path "$root/.git" -prune -o -type l -print -quit)" || fail symlink-present
test -z "$(find "$root" -path "$root/.git" -prune -o \( -type d -name __pycache__ -o -type f -name '*.pyc' \) -print -quit)" || fail python-cache-present
test -z "$(find "$root" -path "$root/.git" -prune -o -type f -size +10M -print -quit)" || fail oversized-file
elf_path=$(find "$root" -path "$root/.git" -prune -o -type f -exec sh -c '
	for path do
		magic=$(od -An -tx1 -N4 "$path" | tr -d " \\n")
		test "$magic" = 7f454c46 && { printf "%s\\n" "$path"; exit 0; }
	done
	exit 1
' sh {} + 2>/dev/null | head -1)
test -z "$elf_path" || fail "elf-binary-present:$elf_path"
test -z "$(find "$root" -path "$root/.git" -prune -o -type f \( \
	-name '*.img' -o -name '*.img.gz' -o -name '*.mbn' -o -name '*.mdt' -o \
	-name '*.b00' -o -name '*.b01' -o -name '*.b02' -o -name '*.b03' -o \
	-name '*.b04' -o -name '*.elf' -o -name '*.bin' -o -name '*.fw' -o \
	-name '*.tlv' \) -print -quit)" || fail proprietary-or-binary-payload

# Account selection belongs to pmbootstrap/the image finalizer. Runtime source
# must not couple service identity, paths or authorization to the developer's
# historical account name or UID.
if grep -RIlE \
	'(/home/m1892|(^|[^0-9])10000([^0-9]|$)|subject\.user[[:space:]]*==[[:space:]]*"m1892"|user[[:space:]]*=[[:space:]]*"m1892")' \
	"$root/src/runtime" "$root/src/runtime-inputs" 2>/dev/null | grep -q .; then
	fail runtime-account-hardcode
fi

if grep -RIlE --exclude-dir=.git --exclude=verify-public-tree.sh \
	'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|ssh-(rsa|ed25519|ecdsa)[[:space:]]+[A-Za-z0-9+/]{20,}|github_pat_|ghp_|AppData/Local/Temp|/mnt/[c-z]/Users/[^/[:space:]]+|[A-Za-z]:[/\\]Users[/\\][^/\\[:space:]]+|device-capture/|892Q[A-Z0-9]+|(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)' \
	"$root" 2>/dev/null | grep -q .; then
	fail private-or-engineering-reference
fi
if grep -RIlEi --exclude-dir=.git --exclude=verify-public-tree.sh \
	'^[[:space:]]*(ssid|psk|wep-key[0-9]*|password)[[:space:]]*=' \
	"$root" 2>/dev/null | grep -q .; then
	fail network-credential-present
fi
# Public documents must use stable feature and release names so every reader
# can follow the installation, recovery, status and release narrative.
if find "$root" -maxdepth 1 -type f -name '*.md' -print0 | \
	xargs -0 grep -IlE '(^|[^A-Za-z0-9_])R[0-9]{2,}([^A-Za-z0-9_]|$)' | grep -q .; then
	fail public-document-internal-revision
fi

for script in "$root"/scripts/*; do
	grep -Fq 'SPDX-License-Identifier: MIT' "$script" || fail "script-license:$script"
done
grep -Fq 'img2fullsimg.py" --verify "$userdata"' "$root/scripts/flash-m1892.sh" ||
	fail flash-does-not-require-full-sparse
grep -Fq 'userdata logical size is not exactly 8 GiB' "$root/scripts/flash-m1892.sh" ||
	fail flash-does-not-require-eight-gib-logical-size
for document in QUICK_START.md QUICK_START_EN.md INSTALL.md INSTALL_EN.md \
	FIRMWARE.md FIRMWARE_EN.md; do
	grep -Fq 'img2fullsimg.py --verify-against' "$root/$document" ||
		fail "documentation-does-not-verify-full-sparse:$document"
done
grep -Fq 'if len(sys.argv) == 4 and sys.argv[1] == "--verify-against"' \
	"$root/scripts/img2fullsimg.py" || fail missing-full-sparse-byte-comparison

# The public Bluetooth DTS carries one all-zero layout placeholder so old dtc
# trees can be canonicalized deterministically.  The canonicalizer requires that
# exact zero value and removes the property; the final-DTB verifier separately
# rejects any remaining local-bd-address.  Permit only this source placeholder,
# never a second property or any non-zero device identity.
bd_matches=$(grep -RIlE --exclude-dir=.git --exclude=verify-public-tree.sh \
	'local-bd-address[[:space:]]*=[[:space:]]*\[' "$root" 2>/dev/null || true)
bd_count=0
for bd_placeholder in $bd_matches; do
	case $bd_placeholder in
		"$root/src/kernel-inputs/postmarketos/linux-meizu-m1892/sdm845-meizu-m1892-r86-bluetooth-passive.dts"|\
		"$root/src/pmaports/linux-meizu-m1892/sdm845-meizu-m1892-r86-bluetooth-passive.dts") ;;
		*) fail unexpected-bluetooth-address-property ;;
	esac
	test "$(grep -Ec '^[[:space:]]*local-bd-address[[:space:]]*=[[:space:]]*\[00 00 00 00 00 00\];[[:space:]]*$' "$bd_placeholder")" = 1 || \
		fail invalid-bluetooth-address-placeholder
	bd_count=$((bd_count + 1))
done
test "$bd_count" = 2 || fail missing-bluetooth-address-layout-placeholder

echo "files=$(find "$root" -path "$root/.git" -prune -o -type f -print | wc -l)"
echo M1892_PUBLIC_TREE_PASS
