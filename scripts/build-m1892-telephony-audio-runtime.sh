#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

output=${1:-}
source_output=${2:-}
offline_source=${M1892_TELEPHONY_OFFLINE_SOURCE_DIR:-}
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tree_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
callaudiod_commit=fe87a9267f1e074d19055d7a236e6b6f759af11d
voltd_commit=a7794dd6c8ac216a97dc5a931edab2dfc46eca2a
libqmi_commit=b683efb4716dd512e74456cfee8085058fd95598
qcom_imsd_commit=fd15814d403c13caf874620e48abe83e39b9f4f8
modemmanager_commit=d776ea38d29ca472a12323c1d45002ee19a66f57
pyosmocom_url=https://files.pythonhosted.org/packages/45/a6/c476f25d9402988762e6ace4ebae696c899c9d969e73273255573cd4aadc/pyosmocom-0.0.11-py3-none-any.whl
pyosmocom_sha256=8129e17744b65eada285baf5ddab18a8eb52d704ca7aeeb53a83783cdfa3c3c8
statemachine_url=https://files.pythonhosted.org/packages/bf/2d/1c95ebe84df60d630f8e855d1df2c66368805444ac167e9b50f29eabe917/python_statemachine-2.5.0-py3-none-any.whl
statemachine_sha256=0ed53846802c17037fcb2a92323f4bc0c833290fa9d17a3587c50886c1541e62
source_date_epoch=1788393600
fail() { echo "M1892_TELEPHONY_AUDIO_BUILD_FAIL: $*" >&2; exit 1; }

[ -n "$output" ] || fail missing-output-archive
[ "$(uname -m)" = aarch64 ] || fail requires-aarch64-build-host
[ ! -e "$output" ] || fail output-exists
for command in cc git meson ninja pkg-config python3 sha256sum strip tar unzip wget xargs; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
tar --version 2>/dev/null | grep -Fq 'GNU tar' || fail requires-gnu-tar
if [ -n "$source_output" ]; then
	[ ! -e "$source_output" ] || fail source-output-exists
fi
if [ -n "$offline_source" ]; then
	[ -d "$offline_source/sources" ] || fail offline-source-layout
	[ -d "$offline_source/dependencies" ] || fail offline-dependency-layout
fi

resolve_source()
{
	relative=$1
	for source in \
		"$tree_root/src/runtime-inputs/$relative" \
		"$tree_root/src/telephony/$relative" \
		"$script_dir/../../$relative"; do
		[ -f "$source" ] || continue
		printf '%s\n' "$source"
		return 0
	done
	fail "missing-source:$relative"
}

clone_component()
{
	name=$1
	url=$2
	commit=$3
	destination=$4
	if [ -n "$offline_source" ]; then
		snapshot=$offline_source/sources/$name
		[ -d "$snapshot" ] || fail "missing-offline-snapshot:$name"
		mkdir -p "$destination"
		cp -a "$snapshot/." "$destination/"
		git -C "$destination" init -q
		git -C "$destination" add -A
	else
		git init -q "$destination"
		git -C "$destination" remote add origin "$url"
		git -C "$destination" fetch -q --depth=1 origin "$commit"
		git -C "$destination" checkout -q --detach FETCH_HEAD
		[ "$(git -C "$destination" rev-parse HEAD)" = "$commit" ] ||
			fail "source-commit:$name"
	fi
	case $name in
		callaudiod) expected_tree=6aa6ac7ca1c0438dd7b5d17608cb3555450b0b69 ;;
		81voltd) expected_tree=c39bdb2c332321fcd1e8f9644e58aef6f8590242 ;;
		libqmi) expected_tree=27b5e318d4ba0cce2c94690de54e2094781c935b ;;
		qcom-imsd) expected_tree=f58ebb75e793fb24d04bd926182b38756d8df2ed ;;
		ModemManager) expected_tree=516d319230736bbbdb041ce07a1185c2f33ca323 ;;
		*) fail "unknown-source:$name" ;;
	esac
	[ "$(git -C "$destination" write-tree)" = "$expected_tree" ] ||
		fail "source-tree:$name"
	# Re-root the verified tree with fixed metadata in both online and offline
	# modes. This prevents absolute clone paths and shallow-history state from
	# changing binaries that consult Git during their build.
	find "$destination/.git" -depth -delete
	git -C "$destination" init -q
	git -C "$destination" add -A
	GIT_AUTHOR_NAME=M1892 GIT_AUTHOR_EMAIL=noreply@example.invalid \
	GIT_COMMITTER_NAME=M1892 GIT_COMMITTER_EMAIL=noreply@example.invalid \
	GIT_AUTHOR_DATE="$source_date_epoch +0000" \
	GIT_COMMITTER_DATE="$source_date_epoch +0000" \
		git -C "$destination" commit -q --no-gpg-sign \
		-m "Normalized pinned upstream source"
}

callaudiod_patch=$(resolve_source userspace/telephony/callaudiod-pulse17-split-profile.patch)
callaudio_service=$(resolve_source userspace/telephony/org.mobian_project.CallAudio.service)
q6voiced_source=$(resolve_source m1892-userspace/q6voiced/q6voiced-m1892.c)
q6voiced_config=$(resolve_source m1892-userspace/q6voiced/q6voiced.conf)
q6voiced_service=$(resolve_source m1892-userspace/q6voiced/q6voiced.openrc)
voltd_patch=$(resolve_source userspace/telephony/81voltd-m1892-ip-config.patch)
voltd_service=$(resolve_source userspace/telephony/m1892-81voltd.openrc)
qcom_imsd_patch=$(resolve_source userspace/telephony/qcom-imsd-m1892.patch)
qcom_imsd_launcher=$(resolve_source userspace/telephony/m1892-qcom-imsd)
qcom_imsd_service=$(resolve_source userspace/telephony/m1892-qcom-imsd.openrc)
modemmanager_patch=$(resolve_source userspace/telephony/modemmanager-qmi-sms-over-ims.patch)

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-telephony-audio.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
export CFLAGS="-O2 -pipe -ffile-prefix-map=$work=/usr/src/m1892-build -fdebug-prefix-map=$work=/usr/src/m1892-build -ffile-prefix-map=$tree_root=/usr/src/m1892-integration -fdebug-prefix-map=$tree_root=/usr/src/m1892-integration"
export SOURCE_DATE_EPOCH=$source_date_epoch
mkdir -p "$root/usr/local/libexec" "$root/usr/local/sbin" "$root/usr/bin" \
	"$root/usr/sbin" \
	"$root/usr/share/dbus-1/services" "$root/etc/init.d" \
	"$root/usr/share/q6voiced" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/callaudiod" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/81voltd" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/libqmi" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/qcom-imsd" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/ModemManager" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/M1892-integration" \
	"$root/opt/m1892-openimsd/lib/girepository-1.0" \
	"$root/opt/m1892-openimsd/bin" "$root/opt/m1892-openimsd/python"

clone_component callaudiod https://gitlab.com/mobian1/callaudiod.git \
	"$callaudiod_commit" "$work/callaudiod"
install -m 0644 "$work/callaudiod/COPYING" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/callaudiod/COPYING"
git -C "$work/callaudiod" apply --check "$callaudiod_patch"
git -C "$work/callaudiod" apply "$callaudiod_patch"
meson setup "$work/callaudiod-build" "$work/callaudiod" \
	--buildtype=release --prefix=/usr
meson compile -C "$work/callaudiod-build" callaudiod
install -m 0755 "$work/callaudiod-build/src/callaudiod" \
	"$root/usr/local/libexec/m1892-callaudiod"

cc -O2 -pipe -fno-ident \
	-ffile-prefix-map="$work"=/usr/src/m1892-build \
	-ffile-prefix-map="$tree_root"=/usr/src/m1892-integration \
	$(pkg-config --cflags alsa dbus-1) \
	-o "$root/usr/bin/q6voiced" "$q6voiced_source" \
	$(pkg-config --libs alsa dbus-1)
strip "$root/usr/bin/q6voiced" "$root/usr/local/libexec/m1892-callaudiod"
install -m 0644 "$q6voiced_config" "$root/usr/share/q6voiced/q6voiced.conf"
install -m 0755 "$q6voiced_service" "$root/etc/init.d/q6voiced"
install -m 0644 "$callaudio_service" \
	"$root/usr/share/dbus-1/services/org.mobian_project.CallAudio.service"
install -m 0644 "$tree_root/licenses/MIT.txt" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/M1892-integration/LICENSE"

clone_component 81voltd https://gitlab.postmarketos.org/modem/81voltd.git \
	"$voltd_commit" "$work/81voltd"
install -m 0644 "$work/81voltd/LICENSE" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/81voltd/LICENSE"
git -C "$work/81voltd" apply --check "$voltd_patch"
git -C "$work/81voltd" apply "$voltd_patch"
meson setup "$work/81voltd-build" "$work/81voltd" \
	--buildtype=release --prefix=/usr
meson compile -C "$work/81voltd-build"
install -m 0755 "$work/81voltd-build/81voltd" \
	"$root/usr/local/sbin/m1892-81voltd"
strip "$root/usr/local/sbin/m1892-81voltd"
install -m 0755 "$voltd_service" "$root/etc/init.d/81voltd"

clone_component libqmi https://gitlab.postmarketos.org/modem/openimsd/libqmi.git \
	"$libqmi_commit" "$work/libqmi"
install -m 0644 "$work/libqmi/COPYING" "$work/libqmi/COPYING.LIB" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/libqmi/"
meson setup "$work/libqmi-build" "$work/libqmi" \
	--buildtype=release --strip --prefix=/usr \
	-Dgtk_doc=false -Dman=false -Dintrospection=true \
	-Dqrtr=true
meson compile -C "$work/libqmi-build"
DESTDIR="$work/libqmi-stage" meson install --no-rebuild \
	-C "$work/libqmi-build"
cp -a "$work/libqmi-stage/usr/lib/"libqmi-glib.so* \
	"$root/opt/m1892-openimsd/lib/"
cp -a "$work/libqmi-stage/usr/lib/girepository-1.0/Qmi-1.0.typelib" \
	"$root/opt/m1892-openimsd/lib/girepository-1.0/"
if [ -x "$work/libqmi-stage/usr/bin/qmicli" ]; then
	cp -a "$work/libqmi-stage/usr/bin/qmicli" \
		"$root/opt/m1892-openimsd/bin/"
fi

clone_component qcom-imsd https://gitlab.postmarketos.org/modem/openimsd/qcom-imsd.git \
	"$qcom_imsd_commit" "$work/qcom-imsd"
install -m 0644 "$work/qcom-imsd/LICENSE.md" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/qcom-imsd/LICENSE.md"
git -C "$work/qcom-imsd" apply --check "$qcom_imsd_patch"
git -C "$work/qcom-imsd" apply "$qcom_imsd_patch"
mkdir -p "$root/opt/m1892-openimsd/qcom-imsd"
cp -a "$work/qcom-imsd/src" "$work/qcom-imsd/imsd.toml" \
	"$root/opt/m1892-openimsd/qcom-imsd/"

# qcom-imsd imports python-statemachine directly and uses osmocom.utils from
# pyosmocom, but its upstream metadata only declares pyosmocom and Alpine does
# not package pyosmocom.  Bundle both pure-Python wheels at pinned hashes so an
# owner image has the exact runtime dependencies even when the public base is
# reused and no target-side network is available.
pyosmocom_wheel=$work/pyosmocom-0.0.11-py3-none-any.whl
statemachine_wheel=$work/python_statemachine-2.5.0-py3-none-any.whl
if [ -n "$offline_source" ]; then
	cp "$offline_source/dependencies/$(basename -- "$pyosmocom_wheel")" \
		"$pyosmocom_wheel"
	cp "$offline_source/dependencies/$(basename -- "$statemachine_wheel")" \
		"$statemachine_wheel"
else
	wget -q -O "$pyosmocom_wheel" "$pyosmocom_url"
	wget -q -O "$statemachine_wheel" "$statemachine_url"
fi
[ "$(sha256sum "$pyosmocom_wheel" | awk '{print $1}')" = "$pyosmocom_sha256" ] ||
	fail pyosmocom-wheel-hash
[ "$(sha256sum "$statemachine_wheel" | awk '{print $1}')" = "$statemachine_sha256" ] ||
	fail statemachine-wheel-hash
unzip -q "$pyosmocom_wheel" -d "$root/opt/m1892-openimsd/python"
unzip -q "$statemachine_wheel" -d "$root/opt/m1892-openimsd/python"
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$root/opt/m1892-openimsd/python" python3 -c \
	'from osmocom.utils import swap_nibbles, Hexstr; from statemachine import State, StateMachine'
install -m 0755 "$qcom_imsd_launcher" "$root/usr/local/sbin/m1892-qcom-imsd"
install -m 0755 "$qcom_imsd_service" "$root/etc/init.d/m1892-qcom-imsd"

# M1892 is LTE packet-switched only on the accepted carrier profile.  Build
# the exact Alpine ModemManager revision with the device-specific QMI WMS
# SMS-on-IMS hint so Chatty and mmcli use IMS instead of a detached CS domain.
clone_component ModemManager \
	https://gitlab.freedesktop.org/mobile-broadband/ModemManager.git \
	"$modemmanager_commit" "$work/ModemManager"
install -m 0644 "$work/ModemManager/COPYING" \
	"$work/ModemManager/COPYING.LIB" \
	"$root/usr/share/licenses/m1892-telephony-audio-runtime/ModemManager/"
git -C "$work/ModemManager" apply --check --unidiff-zero "$modemmanager_patch"
git -C "$work/ModemManager" apply --unidiff-zero "$modemmanager_patch"
meson setup "$work/ModemManager-build" "$work/ModemManager" \
	--buildtype=release --prefix=/usr -Dgtk_doc=false -Dman=false \
	-Dpolkit=permissive -Dsystemdsystemunitdir=no -Dsystemd_journal=false \
	-Dsystemd_suspend_resume=true -Dvapi=false
meson compile -C "$work/ModemManager-build" src/ModemManager
install -m 0755 "$work/ModemManager-build/src/ModemManager" \
	"$root/usr/sbin/ModemManager"
strip "$root/usr/sbin/ModemManager"

cat >"$root/usr/local/libexec/m1892-telephony-audio.build-info" <<EOF
format=m1892-telephony-audio-v2
architecture=aarch64
callaudiod_upstream=$callaudiod_commit
callaudiod_patch_sha256=$(sha256sum "$callaudiod_patch" | awk '{print $1}')
q6voiced_source_sha256=$(sha256sum "$q6voiced_source" | awk '{print $1}')
q6voiced_config_sha256=$(sha256sum "$q6voiced_config" | awk '{print $1}')
q6voiced_service_sha256=$(sha256sum "$q6voiced_service" | awk '{print $1}')
voltd_upstream=$voltd_commit
voltd_patch_sha256=$(sha256sum "$voltd_patch" | awk '{print $1}')
libqmi_upstream=$libqmi_commit
qcom_imsd_upstream=$qcom_imsd_commit
qcom_imsd_patch_sha256=$(sha256sum "$qcom_imsd_patch" | awk '{print $1}')
modemmanager_upstream=$modemmanager_commit
modemmanager_patch_sha256=$(sha256sum "$modemmanager_patch" | awk '{print $1}')
pyosmocom_wheel_sha256=$pyosmocom_sha256
python_statemachine_wheel_sha256=$statemachine_sha256
callaudiod_sha256=$(sha256sum "$root/usr/local/libexec/m1892-callaudiod" | awk '{print $1}')
q6voiced_sha256=$(sha256sum "$root/usr/bin/q6voiced" | awk '{print $1}')
modemmanager_sha256=$(sha256sum "$root/usr/sbin/ModemManager" | awk '{print $1}')
callaudio_service_sha256=$(sha256sum "$callaudio_service" | awk '{print $1}')
EOF

if [ -n "$source_output" ]; then
	source_root=$work/source/m1892-telephony-audio-source
	mkdir -p "$source_root/sources" "$source_root/dependencies" \
		"$source_root/scripts" "$source_root/licenses"
	for source_pair in \
		"$work/callaudiod:callaudiod" \
		"$work/81voltd:81voltd" \
		"$work/libqmi:libqmi" \
		"$work/qcom-imsd:qcom-imsd" \
		"$work/ModemManager:ModemManager"; do
		repository=${source_pair%%:*}
		name=${source_pair#*:}
		mkdir -p "$source_root/sources/$name"
		git -C "$repository" archive --format=tar HEAD | \
			tar -C "$source_root/sources/$name" -xf -
	done
	for relative in \
		userspace/telephony/callaudiod-pulse17-split-profile.patch \
		userspace/telephony/org.mobian_project.CallAudio.service \
		m1892-userspace/q6voiced/q6voiced-m1892.c \
		m1892-userspace/q6voiced/q6voiced.conf \
		m1892-userspace/q6voiced/q6voiced.openrc \
		userspace/telephony/81voltd-m1892-ip-config.patch \
		userspace/telephony/m1892-81voltd.openrc \
		userspace/telephony/qcom-imsd-m1892.patch \
		userspace/telephony/m1892-qcom-imsd \
		userspace/telephony/m1892-qcom-imsd.openrc \
		userspace/telephony/modemmanager-qmi-sms-over-ims.patch; do
		source_file=$(resolve_source "$relative")
		target=$source_root/src/runtime-inputs/$relative
		mkdir -p "$(dirname -- "$target")"
		install -m 0644 "$source_file" "$target"
	done
	install -m 0755 "$tree_root/scripts/build-m1892-telephony-audio-runtime.sh" \
		"$source_root/scripts/"
	install -m 0755 "$tree_root/scripts/verify-m1892-telephony-audio-runtime.sh" \
		"$tree_root/scripts/verify-m1892-telephony-audio-source.sh" \
		"$source_root/scripts/"
	install -m 0644 "$tree_root/licenses/MIT.txt" "$source_root/licenses/"
	install -m 0644 "$pyosmocom_wheel" "$statemachine_wheel" \
		"$source_root/dependencies/"
	cat >"$source_root/SOURCE-REVISIONS.txt" <<EOF
callaudiod $callaudiod_commit 6aa6ac7ca1c0438dd7b5d17608cb3555450b0b69
81voltd $voltd_commit c39bdb2c332321fcd1e8f9644e58aef6f8590242
libqmi $libqmi_commit 27b5e318d4ba0cce2c94690de54e2094781c935b
qcom-imsd $qcom_imsd_commit f58ebb75e793fb24d04bd926182b38756d8df2ed
ModemManager $modemmanager_commit 516d319230736bbbdb041ce07a1185c2f33ca323
pyosmocom $pyosmocom_sha256
python-statemachine $statemachine_sha256
EOF
	cat >"$source_root/README.md" <<'EOF'
# M1892 telephony/audio corresponding source

This archive contains a Git-tree-verified snapshot of every pinned upstream
component, all
M1892 integration inputs, dependency wheels and license material used by the
runtime build. On Alpine aarch64, install its build dependencies first:

```sh
apk add alsa-lib-dev appstream-dev bash-completion-dev build-base dbus-dev \
  elogind-dev git glib-dev gobject-introspection-dev libgudev-dev \
  libmbim-dev libqmi-dev libqrtr-glib-dev linux-headers meson \
  modemmanager-dev pkgconf polkit-dev pulseaudio-dev python3 qrtr-dev \
  samurai tar unzip wget
```

Rebuild without network access from the archive root:

```sh
M1892_TELEPHONY_OFFLINE_SOURCE_DIR="$PWD" \
  ./scripts/build-m1892-telephony-audio-runtime.sh \
  "$PWD/m1892-telephony-audio-runtime.tar.gz"
./scripts/verify-m1892-telephony-audio-runtime.sh \
  "$PWD/m1892-telephony-audio-runtime.tar.gz"
```

The offline-source environment variable forbids network source clones and
uses only the bundled source snapshots and wheel files.
EOF
	(cd "$source_root" && find . -type f ! -name MANIFEST.sha256 -print0 | \
		LC_ALL=C sort -z | xargs -0 sha256sum) >"$source_root/MANIFEST.sha256"
	mkdir -p "$(dirname -- "$source_output")"
	tar --format=gnu --sort=name --mtime="@$source_date_epoch" \
		--owner=0 --group=0 --numeric-owner \
		--mode='u+rwX,go+rX,go-w' -C "$work/source" -czf "$source_output" \
		m1892-telephony-audio-source
	(cd "$(dirname -- "$source_output")" && sha256sum "$(basename -- "$source_output")") \
		>"$source_output.sha256"
fi

(cd "$root" && find etc opt usr -type f -print0 | LC_ALL=C sort -z | \
	xargs -0 sha256sum) >"$root/MANIFEST.sha256"
mkdir -p "$(dirname -- "$output")"
# Alpine's GNU tar package is an explicit build dependency. Normalize metadata
# so network and corresponding-source rebuilds are byte-comparable.
tar --format=gnu --sort=name --mtime="@$source_date_epoch" \
	--owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
	-C "$root" -czf "$output" MANIFEST.sha256 etc opt usr
(cd "$(dirname -- "$output")" && sha256sum "$(basename -- "$output")") \
	>"$output.sha256"
echo "M1892_TELEPHONY_AUDIO_BUILD_PASS output=$output"
