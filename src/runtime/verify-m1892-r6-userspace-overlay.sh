#!/bin/sh
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
archive=$script_dir/artifacts/m1892-mainline-daily-2026.08-r6-userspace-overlay.tar.gz
fail() { echo "M1892_R6_OVERLAY_VERIFY_FAIL: $*" >&2; exit 1; }
test -s "$archive" || fail archive-missing
test -s "$archive.sha256" || fail archive-hash-missing
(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256") >/dev/null || fail archive-hash
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
tar -C "$tmp" -xzf "$archive"
root=$tmp/m1892-mainline-daily-2026.08-r6-userspace-overlay
test -x "$root/install.sh" || fail installer
sh -n "$root/install.sh" || fail installer-syntax
(cd "$root" && sha256sum -c BUNDLE_MANIFEST.sha256 >/dev/null) || fail bundle-manifest
test "$(awk 'END {print NR}' "$root/PAYLOAD_MANIFEST.tsv")" -gt 2500 || fail payload-too-small
listing=$tmp/archive.list
tar -tzf "$archive" >"$listing"
for forbidden in 'NetworkManager/system-connections' '/root/.ssh' '/ROMs/'; do
	! grep -Fq "$forbidden" "$listing" || fail "private-path:$forbidden"
done
! grep -Eq '/home/[^/]+/(ES-DE|\.ssh)(/|$)' "$listing" ||
	fail private-user-home-content
! awk -F '\t' '$4 ~ /^\/usr\/lib\/firmware\// { found=1 } END { exit !found }' \
	"$root/PAYLOAD_MANIFEST.tsv" || fail proprietary-firmware-in-overlay
grep -Fq '/usr/local/bin/es-de' "$root/PAYLOAD_MANIFEST.tsv" || fail esde
grep -Fq '/usr/local/bin/PPSSPPSDL' "$root/PAYLOAD_MANIFEST.tsv" || fail ppsspp
grep -Fq '/usr/lib/m1892/speaker/snd-soc-cs35l41-r442.ko' "$root/PAYLOAD_MANIFEST.tsv" || fail speaker
grep -Fq '/usr/local/sbin/m1892-daily-health' "$root/PAYLOAD_MANIFEST.tsv" || fail health
grep -Fq '/usr/local/sbin/m1892-rmtfs-shadow' "$root/PAYLOAD_MANIFEST.tsv" || fail rmtfs-shadow
grep -Fq '/etc/init.d/m1892-rmtfs-shadow' "$root/PAYLOAD_MANIFEST.tsv" || fail rmtfs-shadow-openrc
grep -Fq '/usr/local/sbin/m1892-radio-bootstrap' "$root/PAYLOAD_MANIFEST.tsv" || fail radio-bootstrap
grep -Fq '/etc/init.d/m1892-radio-bootstrap' "$root/PAYLOAD_MANIFEST.tsv" || fail radio-bootstrap-openrc
grep -Fq '/etc/modprobe.d/m1892-radio-order.conf' "$root/PAYLOAD_MANIFEST.tsv" || fail radio-order
grep -Fxq 'softdep qcom_q6v5_mss pre: qcom_pd_mapper' \
	"$root/payload/etc/modprobe.d/m1892-radio-order.conf" || fail radio-order-content
grep -Fq "modprobe qcom_pd_mapper || fail 'qcom_pd_mapper load failed'" \
	"$root/payload/usr/local/sbin/m1892-radio-bootstrap" || fail radio-bootstrap-pd-mapper-load
grep -Fq "test -d /sys/module/qcom_pd_mapper || fail 'qcom_pd_mapper is not active'" \
	"$root/payload/usr/local/sbin/m1892-radio-bootstrap" || fail radio-bootstrap-pd-mapper-gate
grep -Fq 'test -L /lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn' \
	"$root/payload/usr/local/sbin/m1892-radio-bootstrap" || fail radio-bootstrap-wlanmdsp-link-gate
grep -Fq "grep -qx 'pd_mapper=loaded' /run/m1892-radio-bootstrap.state" \
	"$root/payload/usr/local/sbin/m1892-daily-health" || fail health-pd-mapper-state
grep -Fq 'test -L /lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn' \
	"$root/payload/usr/local/sbin/m1892-daily-health" || fail health-wlanmdsp-link-gate
grep -Fq '/usr/local/sbin/m1892-persist-sensors-import' "$root/PAYLOAD_MANIFEST.tsv" || fail persist-sensors-import
grep -Fq '/usr/local/sbin/m1892-venus-coldload-r521' "$root/PAYLOAD_MANIFEST.tsv" || fail venus
grep -Fq '/usr/local/sbin/m1892-safe-fastboot' "$root/PAYLOAD_MANIFEST.tsv" || fail safe-fastboot
grep -Fq '/usr/libexec/m1892/reboot-fastboot-frozen' "$root/PAYLOAD_MANIFEST.tsv" || fail reboot-fastboot-helper
grep -Fq '5a664ebdeb0ecb046b988d62c267460f71b27a14930b56aed9097b5074e951c7' \
	"$root/PAYLOAD_MANIFEST.tsv" || fail reboot-fastboot-helper-hash
grep -Fq '/usr/bin/phoc' "$root/PAYLOAD_MANIFEST.tsv" || fail phoc-r523
grep -Fq 'e157995638e35f0c61393443ded44fcd5f7028875f3df7d5a753114c298af36a' \
	"$root/PAYLOAD_MANIFEST.tsv" || fail phoc-r523-hash
grep -Fq '/etc/polkit-1/rules.d/48-m1892-telephony.rules' \
	"$root/PAYLOAD_MANIFEST.tsv" || fail telephony-polkit
grep -Fq 'org.freedesktop.ModemManager1.Voice' \
	"$root/payload/etc/polkit-1/rules.d/48-m1892-telephony.rules" ||
	fail telephony-polkit-voice
grep -Fq 'subject.isInGroup("plugdev")' \
	"$root/payload/etc/polkit-1/rules.d/48-m1892-telephony.rules" ||
	fail telephony-polkit-boundary
grep -Fq 'CapturePCM "hw:${CardId},3"' \
	"$root/payload/usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf" ||
	fail telephony-capture-pcm
grep -Fq 'SectionDevice."Earpiece"' \
	"$root/payload/usr/share/alsa/ucm2/Meizu/m1892/VoiceCall.conf" ||
	fail telephony-earpiece-port
grep -Fq '81voltd:default' "$root/install.sh" || fail 81voltd-runlevel
grep -Fq 'q6voiced:default' "$root/install.sh" || fail q6voiced-runlevel
grep -Fq '/usr/bin/81voltd' "$root/REQUIRED_RUNTIME.txt" || fail 81voltd-runtime
echo "archive_sha256=$(sha256sum "$archive" | awk '{print $1}')"
echo "payload_files=$(awk 'END {print NR}' "$root/PAYLOAD_MANIFEST.tsv")"
echo M1892_R6_OVERLAY_VERIFY_PASS
