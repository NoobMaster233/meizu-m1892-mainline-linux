#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

archive=${1:-}
fail() { echo "M1892_TELEPHONY_AUDIO_VERIFY_FAIL: $*" >&2; exit 1; }
[ -f "$archive" ] || fail missing-archive
for command in awk find grep od python3 sha256sum strings tar; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
tar -tzf "$archive" | awk '
	/^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
	END { exit bad ? 1 : 0 }
' || fail unsafe-archive-path
work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-telephony-audio-verify.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
tar -C "$work" -xzf "$archive"
(cd "$work" && sha256sum -c MANIFEST.sha256 >/dev/null) || fail manifest

info=$work/usr/local/libexec/m1892-telephony-audio.build-info
[ -f "$info" ] || fail missing-build-info
grep -qx 'format=m1892-telephony-audio-v2' "$info" || fail build-info-format
grep -qx 'architecture=aarch64' "$info" || fail build-info-architecture
grep -qx 'callaudiod_upstream=fe87a9267f1e074d19055d7a236e6b6f759af11d' "$info" ||
	fail callaudiod-upstream
grep -qx 'callaudiod_patch_sha256=ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e' "$info" ||
	fail callaudiod-patch
grep -qx 'q6voiced_source_sha256=2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4' "$info" ||
	fail q6voiced-source
grep -qx 'voltd_upstream=a7794dd6c8ac216a97dc5a931edab2dfc46eca2a' "$info" ||
	fail voltd-upstream
grep -qx 'voltd_patch_sha256=6fb26defb0b4935bb93423c1220e7e60c8e2f8791587bcecfa6643066ecd541f' "$info" ||
	fail voltd-patch
grep -qx 'libqmi_upstream=b683efb4716dd512e74456cfee8085058fd95598' "$info" ||
	fail libqmi-upstream
grep -qx 'qcom_imsd_upstream=fd15814d403c13caf874620e48abe83e39b9f4f8' "$info" ||
	fail qcom-imsd-upstream
grep -qx 'qcom_imsd_patch_sha256=3a0013d61e09000d72664e50ba532538545a0ae335973944bc9516ec9e2765c2' "$info" ||
	fail qcom-imsd-patch
grep -qx 'modemmanager_upstream=d776ea38d29ca472a12323c1d45002ee19a66f57' "$info" ||
	fail modemmanager-upstream
grep -qx 'modemmanager_patch_sha256=26ada503b1cae88f77f9eda2936c9223f664f88ae40e7301ee619171328ac0d8' "$info" ||
	fail modemmanager-patch
grep -qx 'pyosmocom_wheel_sha256=8129e17744b65eada285baf5ddab18a8eb52d704ca7aeeb53a83783cdfa3c3c8' "$info" ||
	fail pyosmocom-wheel
grep -qx 'python_statemachine_wheel_sha256=0ed53846802c17037fcb2a92323f4bc0c833290fa9d17a3587c50886c1541e62' "$info" ||
	fail python-statemachine-wheel
for binary in usr/local/libexec/m1892-callaudiod usr/bin/q6voiced \
	usr/local/sbin/m1892-81voltd usr/sbin/ModemManager; do
	[ -x "$work/$binary" ] || fail "missing-executable:$binary"
	[ "$(od -An -tx1 -N4 "$work/$binary" | tr -d ' \n')" = 7f454c46 ] ||
		fail "not-elf:$binary"
done
strings "$work/usr/sbin/ModemManager" | grep -Fq \
	'qmi_message_wms_raw_send_input_set_sms_on_ims' || fail modemmanager-sms-on-ims
strings "$work/usr/sbin/ModemManager" | grep -Fq \
	'SMS over IMS unavailable; retrying once through the default domain' ||
	fail modemmanager-sms-domain-fallback
service=$work/usr/share/dbus-1/services/org.mobian_project.CallAudio.service
grep -qx 'Exec=/usr/local/libexec/m1892-callaudiod' "$service" ||
	fail callaudio-service-exec
grep -Fq 'command=/usr/local/sbin/m1892-81voltd' "$work/etc/init.d/81voltd" ||
	fail voltd-service-exec
grep -Fq 'command=/usr/local/sbin/m1892-qcom-imsd' \
	"$work/etc/init.d/m1892-qcom-imsd" || fail qcom-imsd-service-exec
test -x "$work/usr/local/sbin/m1892-qcom-imsd" || fail qcom-imsd-launcher
test -f "$work/opt/m1892-openimsd/qcom-imsd/imsd.toml" || fail qcom-imsd-config
test -f "$work/opt/m1892-openimsd/python/osmocom/utils.py" || fail pyosmocom-runtime
test -f "$work/opt/m1892-openimsd/python/statemachine/__init__.py" ||
	fail python-statemachine-runtime
grep -Fq ':$prefix/python' "$work/usr/local/sbin/m1892-qcom-imsd" ||
	fail qcom-imsd-pythonpath
PYTHONPATH="$work/opt/m1892-openimsd/python" python3 -c \
	'from osmocom.utils import swap_nibbles, Hexstr; from statemachine import State, StateMachine' ||
	fail qcom-imsd-python-imports
grep -Fq 'command_background=true' "$work/etc/init.d/q6voiced" ||
	fail q6voiced-openrc-background
grep -Fq 'pidfile="/run/q6voiced.pid"' "$work/etc/init.d/q6voiced" ||
	fail q6voiced-openrc-pidfile
grep -Fq 'command_user="nobody:audio"' "$work/etc/init.d/q6voiced" ||
	fail q6voiced-openrc-user
[ -s "$work/usr/share/q6voiced/q6voiced.conf" ] || fail q6voiced-config
[ -s "$work/opt/m1892-openimsd/python/pyosmocom-0.0.11.dist-info/licenses/COPYING" ] ||
	fail pyosmocom-license
[ -s "$work/opt/m1892-openimsd/python/python_statemachine-2.5.0.dist-info/licenses/LICENSE" ] ||
	fail statemachine-license
for license in \
	usr/share/licenses/m1892-telephony-audio-runtime/callaudiod/COPYING \
	usr/share/licenses/m1892-telephony-audio-runtime/81voltd/LICENSE \
	usr/share/licenses/m1892-telephony-audio-runtime/libqmi/COPYING \
	usr/share/licenses/m1892-telephony-audio-runtime/libqmi/COPYING.LIB \
	usr/share/licenses/m1892-telephony-audio-runtime/qcom-imsd/LICENSE.md \
	usr/share/licenses/m1892-telephony-audio-runtime/ModemManager/COPYING \
	usr/share/licenses/m1892-telephony-audio-runtime/ModemManager/COPYING.LIB \
	usr/share/licenses/m1892-telephony-audio-runtime/M1892-integration/LICENSE; do
	[ -s "$work/$license" ] || fail "missing-license:$license"
done
test -f "$work/opt/m1892-openimsd/lib/girepository-1.0/Qmi-1.0.typelib" ||
	fail qmi-typelib
test -L "$work/opt/m1892-openimsd/lib/libqmi-glib.so.5" || fail qmi-soname-link
[ "$(find "$work/etc" "$work/opt" "$work/usr" -type f | wc -l)" -ge 18 ] ||
	fail unexpected-file-count
echo "M1892_TELEPHONY_AUDIO_VERIFY_PASS archive=$archive"
