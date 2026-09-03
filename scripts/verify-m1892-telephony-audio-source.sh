#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

archive=${1:-}
fail() { echo "M1892_TELEPHONY_SOURCE_VERIFY_FAIL: $*" >&2; exit 1; }
[ -f "$archive" ] || fail missing-archive
for command in find git grep sha256sum tar wc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
tar -tzf "$archive" | grep -Eq '^m1892-telephony-audio-source/' || fail layout
tar -tzf "$archive" | grep -Eq '(^|/)\.\.(/|$)|^/' && fail unsafe-path || true
work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-telephony-source-verify.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
tar -C "$work" -xzf "$archive"
root=$work/m1892-telephony-audio-source
(cd "$root" && sha256sum -c MANIFEST.sha256 >/dev/null) || fail manifest
check_sha256()
{
	expected=$1
	path=$2
	[ -f "$root/$path" ] || fail "missing-integration:$path"
	[ "$(sha256sum "$root/$path" | awk '{print $1}')" = "$expected" ] ||
		fail "integration-hash:$path"
}
for source_revision in \
	'callaudiod fe87a9267f1e074d19055d7a236e6b6f759af11d 6aa6ac7ca1c0438dd7b5d17608cb3555450b0b69' \
	'81voltd a7794dd6c8ac216a97dc5a931edab2dfc46eca2a c39bdb2c332321fcd1e8f9644e58aef6f8590242' \
	'libqmi b683efb4716dd512e74456cfee8085058fd95598 27b5e318d4ba0cce2c94690de54e2094781c935b' \
	'qcom-imsd fd15814d403c13caf874620e48abe83e39b9f4f8 f58ebb75e793fb24d04bd926182b38756d8df2ed' \
	'ModemManager d776ea38d29ca472a12323c1d45002ee19a66f57 516d319230736bbbdb041ce07a1185c2f33ca323' \
	'pyosmocom 8129e17744b65eada285baf5ddab18a8eb52d704ca7aeeb53a83783cdfa3c3c8' \
	'python-statemachine 0ed53846802c17037fcb2a92323f4bc0c833290fa9d17a3587c50886c1541e62'; do
	grep -Fxq "$source_revision" "$root/SOURCE-REVISIONS.txt" ||
		fail "source-revision:$source_revision"
done
[ "$(wc -l <"$root/SOURCE-REVISIONS.txt")" = 7 ] || fail unexpected-revision-count
for source_pair in \
	'callaudiod:6aa6ac7ca1c0438dd7b5d17608cb3555450b0b69' \
	'81voltd:c39bdb2c332321fcd1e8f9644e58aef6f8590242' \
	'libqmi:27b5e318d4ba0cce2c94690de54e2094781c935b' \
	'qcom-imsd:f58ebb75e793fb24d04bd926182b38756d8df2ed' \
	'ModemManager:516d319230736bbbdb041ce07a1185c2f33ca323'; do
	name=${source_pair%%:*}
	expected_tree=${source_pair#*:}
	snapshot=$root/sources/$name
	[ -d "$snapshot" ] || fail "missing-source:$name"
	mkdir "$work/verify-$name"
	cp -a "$snapshot/." "$work/verify-$name/"
	git -C "$work/verify-$name" init -q
	git -C "$work/verify-$name" add -A
	[ "$(git -C "$work/verify-$name" write-tree)" = "$expected_tree" ] ||
		fail "source-tree:$name"
done
check_sha256 ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e \
	src/runtime-inputs/userspace/telephony/callaudiod-pulse17-split-profile.patch
check_sha256 cf04b155faa8334401ad212039856961d8a26502e0b70168314bf6614cd8d9c5 \
	src/runtime-inputs/userspace/telephony/org.mobian_project.CallAudio.service
check_sha256 2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4 \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced-m1892.c
check_sha256 3a73c9785d2def3717d09f84ba00c097504457c060a28d254a2793cbc56dbc87 \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced.conf
check_sha256 fe9168fce4b0ae39b722908297e3bab04bde3771b8bd685302a06271aca67423 \
	src/runtime-inputs/m1892-userspace/q6voiced/q6voiced.openrc
check_sha256 6fb26defb0b4935bb93423c1220e7e60c8e2f8791587bcecfa6643066ecd541f \
	src/runtime-inputs/userspace/telephony/81voltd-m1892-ip-config.patch
check_sha256 cabe3b4e84ab204f9ed1a877f2a8c67406db272624b2498bd2fb8dde15c3499b \
	src/runtime-inputs/userspace/telephony/m1892-81voltd.openrc
check_sha256 3a0013d61e09000d72664e50ba532538545a0ae335973944bc9516ec9e2765c2 \
	src/runtime-inputs/userspace/telephony/qcom-imsd-m1892.patch
check_sha256 5f1de9a5e22e2b581fc1fb4b79d18fc954bc6e8908d4d9ba99e9bde533caee20 \
	src/runtime-inputs/userspace/telephony/m1892-qcom-imsd
check_sha256 61c753396102e26e302a47e1d37f85e86ace515078277de39d128d2f96a1a2c6 \
	src/runtime-inputs/userspace/telephony/m1892-qcom-imsd.openrc
check_sha256 26ada503b1cae88f77f9eda2936c9223f664f88ae40e7301ee619171328ac0d8 \
	src/runtime-inputs/userspace/telephony/modemmanager-qmi-sms-over-ims.patch
for integration in licenses/MIT.txt \
	scripts/build-m1892-telephony-audio-runtime.sh \
	scripts/verify-m1892-telephony-audio-runtime.sh README.md; do
	[ -s "$root/$integration" ] || fail "missing-integration:$integration"
done
printf '%s  %s\n' \
	8129e17744b65eada285baf5ddab18a8eb52d704ca7aeeb53a83783cdfa3c3c8 \
	"$root/dependencies/pyosmocom-0.0.11-py3-none-any.whl" | sha256sum -c - >/dev/null ||
	fail pyosmocom-source
printf '%s  %s\n' \
	0ed53846802c17037fcb2a92323f4bc0c833290fa9d17a3587c50886c1541e62 \
	"$root/dependencies/python_statemachine-2.5.0-py3-none-any.whl" | sha256sum -c - >/dev/null ||
	fail python-statemachine-source
echo "M1892_TELEPHONY_SOURCE_VERIFY_PASS archive=$archive"
