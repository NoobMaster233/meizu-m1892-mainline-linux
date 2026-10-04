#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

source_archive=${1:-}
upstream_libqmi_archive=${2:-}
output_dir=${3:-}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)

source_sha=4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843
upstream_libqmi_sha=56b236ae169a91b7b9eea0e43810b8ce726568d8d3d3b2f65d85dc0ec50cce60
voltd_commit=a7794dd6c8ac216a97dc5a931edab2dfc46eca2a
openimsd_libqmi_commit=b683efb4716dd512e74456cfee8085058fd95598
qcom_imsd_commit=fd15814d403c13caf874620e48abe83e39b9f4f8
upstream_libqmi_commit=972c8b78eb8e3cb4ea8c12c6eabd6167c56ed4eb
modemmanager_commit=d776ea38d29ca472a12323c1d45002ee19a66f57
source_date_epoch=1789056000

fail() { echo "M1892_IMS_RUNTIME_BUILD_FAIL: $*" >&2; exit 1; }

[ -f "$source_archive" ] && [ -f "$upstream_libqmi_archive" ] &&
	[ -n "$output_dir" ] || {
	echo "usage: $0 TELEPHONY_SOURCE_TAR UPSTREAM_LIBQMI_TAR ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ "$(uname -m)" = aarch64 ] || fail requires-native-aarch64
[ ! -e "$output_dir" ] || fail output-exists
[ "$(sha256sum "$source_archive" | awk '{print $1}')" = "$source_sha" ] ||
	fail source-archive-hash
[ "$(sha256sum "$upstream_libqmi_archive" | awk '{print $1}')" = "$upstream_libqmi_sha" ] ||
	fail upstream-libqmi-hash
for command in cc cmp cp cut diff dpkg-query find install meson mktemp msgfmt ninja \
	patch patchelf pkg-config python3 readelf sha256sum strings strip tar touch unzip xargs \
	xsltproc; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
for module in dbus-1 gio-2.0 gio-unix-2.0 glib-2.0 gmodule-2.0 \
	gobject-2.0 gobject-introspection-1.0 gudev-1.0 mm-glib qmi-glib \
	qrtr qrtr-glib libudev polkit-gobject-1 libsystemd; do
	pkg-config --exists "$module" || fail "missing-pkg-config:$module"
done

old_voltd_patch=src/runtime-inputs/userspace/telephony/81voltd-m1892-ip-config.patch
old_qcom_patch=src/runtime-inputs/userspace/telephony/qcom-imsd-m1892.patch
mm_patch=src/runtime-inputs/userspace/telephony/modemmanager-qmi-sms-over-ims.patch
new_voltd_patch=$tree_dir/patches/81voltd-debian13-gcc14.patch
no_main_default_patch=$tree_dir/patches/81voltd-debian13-no-main-default.patch
new_qcom_patch=$tree_dir/patches/qcom-imsd-debian13-gi.patch
for file in "$new_voltd_patch" "$no_main_default_patch" "$new_qcom_patch"; do
	[ -f "$file" ] || fail "missing-patch:$file"
done

verify_voltd_source()
{
	source=$1
	for required in \
		'gchar *link_argv[] = { "ip", "link", "set", "dev", NULL, "up", NULL };' \
		'gchar *addr_argv[] = { "ip", "-6", "addr", "replace", NULL,' \
		'"/proc/sys/net/ipv6/conf/%s/accept_dad"' \
		'"/proc/sys/net/ipv6/conf/%s/dad_transmits"' \
		'"/proc/sys/net/ipv6/conf/%s/accept_ra_defrtr"' \
		'gchar *flush_argv[] = { "ip", "-6", "route", "flush", "table", "main",' \
		'"default", "dev", NULL, NULL };' \
		'Removed stale IMS main-table defaults from %s'; do
		grep -Fq "$required" "$source" || fail "voltd-source-contract-missing:$required"
	done
	for forbidden in \
		'route_argv' \
		'mm_bearer_ip_config_get_gateway' \
		'"route", "replace", "default"' \
		'"via"' \
		'"metric"' \
		'"1024"'; do
		! grep -Fq "$forbidden" "$source" || fail "voltd-main-default-install-present:$forbidden"
	done
	ra_line=$(grep -nF 'accept_ra_defrtr = g_strdup_printf' "$source" | cut -d: -f1)
	flush_line=$(grep -nF 'run_ip(flush_argv)' "$source" | cut -d: -f1)
	link_line=$(grep -nF 'run_ip(link_argv)' "$source" | cut -d: -f1)
	addr_line=$(grep -nF 'run_ip(addr_argv)' "$source" | cut -d: -f1)
	[ -n "$ra_line" ] && [ -n "$flush_line" ] && [ -n "$link_line" ] && [ -n "$addr_line" ] &&
		[ "$ra_line" -lt "$flush_line" ] && [ "$flush_line" -lt "$link_line" ] &&
		[ "$link_line" -lt "$addr_line" ] || fail voltd-route-policy-order
}

verify_voltd_binary()
{
	binary=$1
	for required in \
		'/proc/sys/net/ipv6/conf/%s/accept_ra_defrtr' \
		'/proc/sys/net/ipv6/conf/%s/accept_dad' \
		'/proc/sys/net/ipv6/conf/%s/dad_transmits' \
		'Removed stale IMS main-table defaults from %s' \
		'Configured IMS IPv6 link %s with %s'; do
		strings "$binary" | grep -Fxq "$required" || fail "voltd-binary-contract-missing:$required"
	done
	for forbidden in metric 1024 via; do
		! strings "$binary" | grep -Fxq "$forbidden" ||
			fail "voltd-binary-main-default-install-present:$forbidden"
	done
}

work=$(mktemp -d "${TMPDIR:-/var/tmp}/m1892-ims-clean.XXXXXXXX")
output_partial=$output_dir.partial.$$
cleanup()
{
	find "$work" -depth -delete 2>/dev/null || true
	[ ! -e "$output_partial" ] || find "$output_partial" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$work/input" "$output_partial"
tar -xzf "$source_archive" -C "$work/input"
source_root=$work/input/m1892-telephony-audio-source
[ -f "$source_root/MANIFEST.sha256" ] || fail source-manifest-absent
(cd "$source_root" && sha256sum -c MANIFEST.sha256 >/dev/null) || fail source-manifest
for path in sources/81voltd sources/libqmi sources/qcom-imsd sources/ModemManager \
	"$old_voltd_patch" "$old_qcom_patch" "$mm_patch" \
	dependencies/pyosmocom-0.0.11-py3-none-any.whl \
	dependencies/python_statemachine-2.5.0-py3-none-any.whl; do
	[ -e "$source_root/$path" ] || fail "source-member-absent:$path"
done

build_one()
{
	name=$1
	vwork=$work/$name
	root=$vwork/root
	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:81voltd"
	mkdir -p "$vwork" "$root/usr/libexec/m1892" \
		"$root/opt/m1892-openimsd/python" "$root/opt/m1892-openimsd/qcom-imsd"

	cp -a "$source_root/sources/81voltd" "$vwork/81voltd"
	(cd "$vwork/81voltd" && patch -s -p1 <"$source_root/$old_voltd_patch" &&
		patch -s -p1 <"$new_voltd_patch" &&
		patch -s --fuzz=0 -p1 <"$no_main_default_patch")
	verify_voltd_source "$vwork/81voltd/qvd-connection.c"
	CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=$vwork=/usr/src/m1892" \
	LDFLAGS='-Wl,--build-id=none' SOURCE_DATE_EPOCH=$source_date_epoch \
		meson setup "$vwork/81-build" "$vwork/81voltd" --buildtype=release --prefix=/usr \
		>"$vwork/81-setup.log" 2>&1 || { tail -80 "$vwork/81-setup.log"; fail "$name:81-setup"; }
	meson compile -C "$vwork/81-build" >"$vwork/81-build.log" 2>&1 || {
		tail -80 "$vwork/81-build.log"; fail "$name:81-build"; }
	install -m 0755 "$vwork/81-build/81voltd" "$root/usr/libexec/m1892/m1892-81voltd"
	strip --strip-unneeded "$root/usr/libexec/m1892/m1892-81voltd"
	verify_voltd_binary "$root/usr/libexec/m1892/m1892-81voltd"

	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:openims-libqmi"
	cp -a "$source_root/sources/libqmi" "$vwork/openims-libqmi"
	CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=$vwork=/usr/src/m1892" \
	LDFLAGS='-Wl,--build-id=none' SOURCE_DATE_EPOCH=$source_date_epoch \
		meson setup "$vwork/openims-libqmi-build" "$vwork/openims-libqmi" \
		--buildtype=release --prefix=/opt/m1892-openimsd --libdir=lib \
		-Dgtk_doc=false -Dman=false -Dbash_completion=false \
		-Dintrospection=true -Dqrtr=true -Drmnet=false \
		>"$vwork/openims-setup.log" 2>&1 || {
		tail -80 "$vwork/openims-setup.log"; fail "$name:openims-setup"; }
	meson compile -C "$vwork/openims-libqmi-build" >"$vwork/openims-build.log" 2>&1 || {
		tail -80 "$vwork/openims-build.log"; fail "$name:openims-build"; }
	DESTDIR="$root" meson install --no-rebuild -C "$vwork/openims-libqmi-build" \
		>"$vwork/openims-install.log" 2>&1 || {
		tail -80 "$vwork/openims-install.log"; fail "$name:openims-install"; }

	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:qcom-imsd"
	cp -a "$source_root/sources/qcom-imsd" "$vwork/qcom-imsd"
	(cd "$vwork/qcom-imsd" && patch -s -p1 <"$source_root/$old_qcom_patch" &&
		patch -s -p1 <"$new_qcom_patch")
	cp -a "$vwork/qcom-imsd/src" "$vwork/qcom-imsd/imsd.toml" \
		"$root/opt/m1892-openimsd/qcom-imsd/"
	unzip -q "$source_root/dependencies/pyosmocom-0.0.11-py3-none-any.whl" \
		-d "$root/opt/m1892-openimsd/python"
	unzip -q "$source_root/dependencies/python_statemachine-2.5.0-py3-none-any.whl" \
		-d "$root/opt/m1892-openimsd/python"
	find "$root/opt/m1892-openimsd" -type d -name __pycache__ -prune -exec find {} -depth -delete \;

	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:upstream-libqmi"
	mkdir -p "$vwork/upstream-libqmi"
	tar -xzf "$upstream_libqmi_archive" -C "$vwork/upstream-libqmi" --strip-components=1
	CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=$vwork=/usr/src/m1892" \
	LDFLAGS='-Wl,--build-id=none' SOURCE_DATE_EPOCH=$source_date_epoch \
		meson setup "$vwork/upstream-libqmi-build" "$vwork/upstream-libqmi" \
		--buildtype=release --prefix=/opt/m1892-mm-libqmi \
		--libdir=lib/aarch64-linux-gnu -Dgtk_doc=false -Dman=false \
		-Dintrospection=false -Dbash_completion=false -Dqrtr=true -Drmnet=true -Dudev=false \
		>"$vwork/qmi-setup.log" 2>&1 || {
		tail -80 "$vwork/qmi-setup.log"; fail "$name:qmi-setup"; }
	meson compile -C "$vwork/upstream-libqmi-build" >"$vwork/qmi-build.log" 2>&1 || {
		tail -80 "$vwork/qmi-build.log"; fail "$name:qmi-build"; }
	DESTDIR="$root" meson install --no-rebuild -C "$vwork/upstream-libqmi-build" \
		>"$vwork/qmi-install.log" 2>&1 || {
		tail -80 "$vwork/qmi-install.log"; fail "$name:qmi-install"; }

	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:ModemManager"
	cp -a "$source_root/sources/ModemManager" "$vwork/ModemManager"
	(cd "$vwork/ModemManager" && patch -s -p1 <"$source_root/$mm_patch")
	qmi_pc=$root/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/pkgconfig
	PKG_CONFIG_PATH="$qmi_pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
	CFLAGS="-O2 -pipe -fno-ident -ffile-prefix-map=$vwork=/usr/src/m1892" \
	SOURCE_DATE_EPOCH=$source_date_epoch \
		meson setup "$vwork/ModemManager-build" "$vwork/ModemManager" \
		--buildtype=release --prefix=/opt/m1892-modemmanager \
		--libdir=lib/aarch64-linux-gnu -Dtests=false -Dexamples=false \
		-Dintrospection=false -Dman=false -Dbash_completion=false -Dmbim=false \
		-Dudevdir=/usr/lib/udev \
		-Dqmi=true -Dqrtr=true -Dbuiltin_plugins=true -Dplugin_generic=enabled \
		-Dplugin_qcom_soc=enabled -Dsystemd_journal=true \
		-Dsystemd_suspend_resume=true -Dsystemdsystemunitdir=no -Dpolkit=strict \
		-Dauto_features=disabled \
		"-Ddist_version=\"1.25.95_git20260709-m1892ims1\"" \
		-Dc_link_args='-Wl,--build-id=none,-rpath,/opt/m1892-modemmanager/lib/aarch64-linux-gnu:/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu' \
		>"$vwork/mm-setup.log" 2>&1 || {
		tail -80 "$vwork/mm-setup.log"; fail "$name:mm-setup"; }
	PKG_CONFIG_PATH="$qmi_pc${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
		meson compile -C "$vwork/ModemManager-build" >"$vwork/mm-build.log" 2>&1 || {
		tail -80 "$vwork/mm-build.log"; fail "$name:mm-build"; }
	DESTDIR="$root" meson install --no-rebuild -C "$vwork/ModemManager-build" \
		>"$vwork/mm-install.log" 2>&1 || {
		tail -80 "$vwork/mm-install.log"; fail "$name:mm-install"; }
	patchelf --set-rpath \
		'/opt/m1892-modemmanager/lib/aarch64-linux-gnu:/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu' \
		"$root/opt/m1892-modemmanager/sbin/ModemManager"

	for file in \
		"$root/opt/m1892-modemmanager/sbin/ModemManager" \
		"$root/opt/m1892-modemmanager/lib/aarch64-linux-gnu/libmm-glib.so.0.11.0" \
		"$root/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/libqmi-glib.so.5.12.0" \
		"$root/opt/m1892-mm-libqmi/libexec/qmi-proxy"; do
		[ -f "$file" ] || fail "$name:installed-file-absent:$file"
	done
	strip --strip-unneeded "$root/opt/m1892-modemmanager/sbin/ModemManager" \
		"$root/opt/m1892-modemmanager/lib/aarch64-linux-gnu/libmm-glib.so.0.11.0" \
		"$root/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/libqmi-glib.so.5.12.0" \
		"$root/opt/m1892-mm-libqmi/libexec/qmi-proxy"
	find "$root" -type f -exec touch -d "@$source_date_epoch" {} +
	echo "M1892_IMS_RUNTIME_BUILD_STAGE: $name:complete"
}

build_one accepted-a
build_one accepted-b
cmp "$work/accepted-a/81voltd/qvd-connection.c" \
	"$work/accepted-b/81voltd/qvd-connection.c" || fail non-reproducible-voltd-source
diff -qr "$work/accepted-a/root" "$work/accepted-b/root" >"$work/reproducibility.diff" || {
	tail -80 "$work/reproducibility.diff"; fail non-reproducible-local-ab; }
echo M1892_IMS_RUNTIME_BUILD_STAGE: reproducibility-pass
cp -a "$work/accepted-a/root/." "$output_partial/"

mm=$output_partial/opt/m1892-modemmanager/sbin/ModemManager
qmi=$output_partial/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu/libqmi-glib.so.5.12.0
[ -x "$mm" ] && [ -x "$output_partial/usr/libexec/m1892/m1892-81voltd" ] &&
	[ -f "$output_partial/opt/m1892-openimsd/lib/girepository-1.0/Qmi-1.0.typelib" ] ||
	fail runtime-members
dynamic=$(readelf -d "$mm")
printf '%s\n' "$dynamic" | grep -E 'RPATH|RUNPATH' || fail modemmanager-runpath-absent
printf '%s\n' "$dynamic" | grep -Fq '/opt/m1892-modemmanager/lib/aarch64-linux-gnu' ||
	fail modemmanager-libmm-runpath
printf '%s\n' "$dynamic" | grep -Fq '/opt/m1892-mm-libqmi/lib/aarch64-linux-gnu' ||
	fail modemmanager-libqmi-runpath
strings "$qmi" | grep -Fq '/opt/m1892-mm-libqmi/libexec/qmi-proxy' ||
	fail qmi-proxy-path
strings "$qmi" | grep -Fq 'm1892-mm-libqmi-972' && fail diagnostic-prefix-leak

(cd "$output_partial" && find opt usr -type f -print0 | LC_ALL=C sort -z |
	xargs -0 sha256sum) >"$output_partial/SHA256SUMS"
dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
	meson ninja-build gcc libc6-dev libglib2.0-dev libmm-glib-dev \
	libqmi-glib-dev libqrtr-glib-dev gobject-introspection patchelf \
	2>/dev/null | LC_ALL=C sort >"$output_partial/build-packages.tsv"
cat >"$output_partial/BUILD-METADATA.txt" <<EOF
component=m1892-debian13-ims-runtime
architecture=aarch64
provenance=clean-native
source_archive_sha256=$source_sha
voltd_upstream=$voltd_commit
openimsd_libqmi_upstream=$openimsd_libqmi_commit
qcom_imsd_upstream=$qcom_imsd_commit
upstream_libqmi_upstream=$upstream_libqmi_commit
upstream_libqmi_archive_sha256=$upstream_libqmi_sha
modemmanager_upstream=$modemmanager_commit
builder_sha256=$(sha256sum "$0" | awk '{print $1}')
voltd_patch_sha256=$(sha256sum "$new_voltd_patch" | awk '{print $1}')
voltd_public_ip_config_patch_sha256=$(sha256sum "$source_root/$old_voltd_patch" | awk '{print $1}')
voltd_gcc14_patch_sha256=$(sha256sum "$new_voltd_patch" | awk '{print $1}')
voltd_no_main_default_patch_sha256=$(sha256sum "$no_main_default_patch" | awk '{print $1}')
voltd_patched_qvd_connection_sha256=$(sha256sum "$work/accepted-a/81voltd/qvd-connection.c" | awk '{print $1}')
voltd_main_default_install=absent
voltd_stale_main_default_cleanup=present
voltd_ra_default_router_acceptance=disabled
voltd_link_address_dad=preserved
qcom_imsd_patch_sha256=$(sha256sum "$new_qcom_patch" | awk '{print $1}')
modemmanager_sha256=$(sha256sum "$mm" | awk '{print $1}')
voltd_sha256=$(sha256sum "$output_partial/usr/libexec/m1892/m1892-81voltd" | awk '{print $1}')
runtime_manifest_sha256=$(sha256sum "$output_partial/SHA256SUMS" | awk '{print $1}')
reproducible_local_ab=yes
result=pass
EOF
grep -Fxq \
	"voltd_no_main_default_patch_sha256=$(sha256sum "$no_main_default_patch" | awk '{print $1}')" \
	"$output_partial/BUILD-METADATA.txt" || fail metadata-no-main-default-patch
for policy in \
	'voltd_main_default_install=absent' \
	'voltd_stale_main_default_cleanup=present' \
	'voltd_ra_default_router_acceptance=disabled' \
	'voltd_link_address_dad=preserved'; do
	grep -Fxq "$policy" "$output_partial/BUILD-METADATA.txt" ||
		fail "metadata-route-policy:$policy"
done
mv "$output_partial" "$output_dir"
echo "manifest_sha256=$(sha256sum "$output_dir/SHA256SUMS" | awk '{print $1}')"
echo M1892_IMS_RUNTIME_BUILD_PASS
