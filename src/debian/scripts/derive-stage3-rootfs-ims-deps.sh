#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

base=${1:-}
debs=${2:-}
output_dir=${3:-}
extra_manifest=${M1892_EXTRA_DEBS_MANIFEST:-}
source_date_epoch=1788739200
base_sha=9eb5c22944b33b1f97c9496696917e883b15ac1700e0479d7caca4cb5f673e6f
artifact_name=m1892-debian13-plasma-mobile-arm64.tar
stage_label=stage3-plasma-mobile-rootfs-ims-deps-derivative
fail() { echo "M1892_IMS_DEPS_DERIVE_FAIL: $*" >&2; exit 1; }

[ -f "$base" ] && [ -d "$debs" ] && [ -n "$output_dir" ] || {
	echo "usage: $0 VERIFIED_STAGE3_TAR IMS_DEBS_DIR ABSOLUTE_OUTPUT_DIR" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) fail output-not-absolute ;; esac
[ ! -e "$output_dir" ] || fail output-exists
[ -f "$base.sha256" ] || fail base-sidecar-absent
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256" >/dev/null) ||
	fail base-sidecar
[ "$(sha256sum "$base" | awk '{print $1}')" = "$base_sha" ] || fail base-hash
for command in awk chroot cp dpkg-deb env find grep id mkdir mktemp mount rmdir \
	sha256sum stat tar umount unshare; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done

check_deb()
{
	file=$1
	hash=$2
	package=$3
	version=$4
	path=$debs/$file
	[ -f "$path" ] || fail "deb-absent:$file"
	[ "$(sha256sum "$path" | awk '{print $1}')" = "$hash" ] || fail "deb-hash:$file"
	[ "$(dpkg-deb -f "$path" Package)" = "$package" ] || fail "deb-package:$file"
	[ "$(dpkg-deb -f "$path" Version)" = "$version" ] || fail "deb-version:$file"
	[ "$(dpkg-deb -f "$path" Architecture)" = arm64 ] || fail "deb-architecture:$file"
}

check_deb gir1.2-glib-2.0_2.84.4-3~deb13u3_arm64.deb \
	c948bcee5f2cc9311059c808b3e236f62a5ba0bc71d1027324f64d673a4bbdcf \
	gir1.2-glib-2.0 2.84.4-3~deb13u3
check_deb libgirepository-1.0-1_1.84.0-1_arm64.deb \
	b711a720dffec60c05710a35bcf78dd9f361237d8c203b925e8ce48337262e43 \
	libgirepository-1.0-1 1.84.0-1
check_deb gir1.2-girepository-2.0_1.84.0-1_arm64.deb \
	bd294852de18f15960353f9c5935f2af75d7178d8b4a6cfa621ba457c6232e5b \
	gir1.2-girepository-2.0 1.84.0-1
check_deb gir1.2-qrtr-1.0_1.2.2-1+b2_arm64.deb \
	7a23e4a6392435ea4ba32bdc1618d4371f766c6af2a4a9c5274ac7dc3a03e7a7 \
	gir1.2-qrtr-1.0 1.2.2-1+b2
check_deb python3-gi_3.50.0-4+b1_arm64.deb \
	ade7445a1cdef0787c8d2e3209800b0aecf7229950e0f296eee0c59bc96c6790 \
	python3-gi 3.50.0-4+b1
check_deb qt6-svg-plugins_6.8.2-3_arm64.deb \
	aa325075fe5483756b5b3f7c56fd82867011216827f95fadbf844aecd3987552 \
	qt6-svg-plugins 6.8.2-3
if [ -n "$extra_manifest" ]; then
	[ -f "$extra_manifest" ] || fail extra-deb-manifest-absent
	(cd "$debs" && sha256sum -c "$extra_manifest" >/dev/null) ||
		fail extra-deb-manifest
	while read -r hash file; do
		case "$hash:$file" in
			????????????????????????????????????????????????????????????????:./*.deb) ;;
			*) fail extra-deb-manifest-entry ;;
		esac
		case $(dpkg-deb -f "$debs/${file#./}" Architecture) in
			arm64|all) ;;
			*) fail "extra-deb-architecture:$file" ;;
		esac
	done <"$extra_manifest"
	artifact_name=m1892-debian13-plasma-mobile-stage6-arm64.tar
	stage_label=stage6-daily-rootfs-ims-deps-derivative
fi

if [ "$(id -u)" -ne 0 ] && [ "${M1892_IMS_DEPS_DERIVE_INNER:-0}" != 1 ]; then
	exec unshare --map-root-user --mount --pid --fork --mount-proc \
		env M1892_IMS_DEPS_DERIVE_INNER=1 "$0" "$@"
fi

work=$(mktemp -d /tmp/m1892-ims-deps-derive.XXXXXXXX)
completed=no
mounted=no
cleanup()
{
	if [ "$mounted" = yes ]; then
		umount -l "$root/dev" "$root/sys" "$root/proc" 2>/dev/null || true
	fi
	find "$work" -depth -delete 2>/dev/null || true
	if [ "$completed" = no ] && [ -d "$output_dir" ] &&
		[ -z "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
		rmdir "$output_dir"
	fi
}
trap cleanup EXIT HUP INT TERM
root=$work/root
stage=$root/run/m1892-ims-deps
mkdir -p "$root" "$stage" "$output_dir"
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev" "$root/proc" "$root/sys"
mount --bind /proc "$root/proc"
mount --bind /sys "$root/sys"
mount --bind /dev "$root/dev"
mounted=yes
for file in \
	gir1.2-glib-2.0_2.84.4-3~deb13u3_arm64.deb \
	libgirepository-1.0-1_1.84.0-1_arm64.deb \
	gir1.2-girepository-2.0_1.84.0-1_arm64.deb \
	gir1.2-qrtr-1.0_1.2.2-1+b2_arm64.deb \
	python3-gi_3.50.0-4+b1_arm64.deb \
	qt6-svg-plugins_6.8.2-3_arm64.deb; do
	cp "$debs/$file" "$stage/$file"
done
if [ -n "$extra_manifest" ]; then
	while read -r hash file; do
		cp "$debs/${file#./}" "$stage/${file#./}"
	done <"$extra_manifest"
fi
DEBIAN_FRONTEND=noninteractive chroot "$root" /bin/sh -c \
	'dpkg -i /run/m1892-ims-deps/*.deb' >/dev/null
umount "$root/dev" "$root/sys" "$root/proc"
mounted=no
find "$stage" -depth -delete
required='gir1.2-glib-2.0 libgirepository-1.0-1 gir1.2-girepository-2.0 gir1.2-qrtr-1.0 python3-gi qt6-svg-plugins'
if [ -n "$extra_manifest" ]; then
	required="$required angelfish qmlkonsole dolphin plasma-systemmonitor kdeconnect flatpak systemd-timesyncd fastfetch kde-spectacle docker.io docker-cli docker-compose docker-buildx retroarch libretro-core-info libretro-gambatte libretro-mgba libretro-nestopia"
fi
for package in $required; do
	chroot "$root" dpkg-query -W -f='${db:Status-Abbrev}\n' "$package" |
		grep -qx 'ii ' || fail "package-not-installed:$package"
done
find "$root/var/cache/ldconfig" -maxdepth 1 -type f -name aux-cache -delete 2>/dev/null || true
: >"$root/var/log/dpkg.log"
artifact=$output_dir/$artifact_name
tar --format=gnu --sort=name --mtime="@$source_date_epoch" --numeric-owner \
	-C "$root" -cf "$artifact" .
sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
printf '%s  %s\n' "$sha" "$artifact_name" >"$artifact.sha256"
cat >"$output_dir/build.env" <<EOF
stage=$stage_label
base_sha256=$base_sha
source_date_epoch=$source_date_epoch
gir_glib_sha256=c948bcee5f2cc9311059c808b3e236f62a5ba0bc71d1027324f64d673a4bbdcf
girepository_sha256=b711a720dffec60c05710a35bcf78dd9f361237d8c203b925e8ce48337262e43
gir_girepository_sha256=bd294852de18f15960353f9c5935f2af75d7178d8b4a6cfa621ba457c6232e5b
gir_qrtr_sha256=7a23e4a6392435ea4ba32bdc1618d4371f766c6af2a4a9c5274ac7dc3a03e7a7
python_gi_sha256=ade7445a1cdef0787c8d2e3209800b0aecf7229950e0f296eee0c59bc96c6790
qt6_svg_plugins_sha256=aa325075fe5483756b5b3f7c56fd82867011216827f95fadbf844aecd3987552
extra_debs_manifest_sha256=$(if [ -n "$extra_manifest" ]; then sha256sum "$extra_manifest" | awk '{print $1}'; else printf 'none'; fi)
builder_sha256=$(sha256sum "$0" | awk '{print $1}')
artifact_size=$bytes
artifact_sha256=$sha
result=pass
EOF
completed=yes
echo "artifact_sha256=$sha"
echo M1892_IMS_DEPS_DERIVE_PASS
