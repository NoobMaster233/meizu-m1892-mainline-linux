#!/usr/bin/env bash
set -euo pipefail

tag=3.16.29
commit=8f212644c46460549035971ab914421180f61a7c
wayland_tag=1.24.0
wayland_commit=736d12ac67c20c60dc406dc49bb06be878501f86
wayland_protocols_tag=1.49
wayland_protocols_commit=ee78491a237eaff9389a0ccf8680521d074407d3
libdrm_tag=libdrm-2.4.129
libdrm_commit=a8e5e10a873f67f557dc70e5407af4553f35edd9
xkbcommon_tag=xkbcommon-1.8.1
xkbcommon_commit=b3465081878e80ca6c11fe35c81787ec374ec15a
pixman_tag=pixman-0.46.4
pixman_commit=9cc163c9da0fb4da430641715313d95a6ec466d9
epoch=1789537750

if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: native-aarch64-required" >&2
    exit 1
fi

for command in git meson ninja cmake pkg-config c++ bison wayland-scanner glslang tar zstd sha256sum readelf; do
    command -v "$command" >/dev/null || {
        echo "M1892_GAMESCOPE_BUILD_FAIL: missing-command:$command" >&2
        exit 1
    }
done

for dependency in \
    libpipewire-0.3 x11 x11-xcb xcb-composite xcb-render xcb-xfixes \
    xcb-icccm xcb-ewmh xcb-res xcb-xinput xcb-errors \
    wayland-client wayland-server vulkan xdamage \
    xcomposite xcursor xrender xext xfixes xxf86vm xtst xres xmu xi \
    libdrm libeis-1.0 xkbcommon sdl2 pixman-1 libudev libdisplay-info \
    libdecor-0 luajit libinput libcap libffi expat pciaccess lcms2 hwdata; do
    pkg-config --exists "$dependency" || {
        echo "M1892_GAMESCOPE_BUILD_FAIL: missing-pkgconfig:$dependency" >&2
        exit 1
    }
done

canonical_build_root=/tmp/m1892-gamescope-${tag}-repro
build_root=${M1892_GAMESCOPE_BUILD_ROOT:-$canonical_build_root}
if [[ "$build_root" != "$canonical_build_root" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: noncanonical-build-root:$build_root" >&2
    exit 1
fi
source_dir=$build_root/source
build_dir=$source_dir/build
stage_dir=$build_root/stage
wayland_source=$build_root/wayland-source
wayland_build=$build_root/wayland-build
wayland_prefix=$build_root/wayland-prefix
wayland_protocols_source=$build_root/wayland-protocols-source
wayland_protocols_build=$build_root/wayland-protocols-build
wayland_protocols_prefix=$build_root/wayland-protocols-prefix
libdrm_source=$build_root/libdrm-source
libdrm_build=$build_root/libdrm-build
libdrm_prefix=$build_root/libdrm-prefix
xkbcommon_source=$build_root/xkbcommon-source
xkbcommon_build=$build_root/xkbcommon-build
xkbcommon_prefix=$build_root/xkbcommon-prefix
pixman_source=$build_root/pixman-source
pixman_build=$build_root/pixman-build
pixman_prefix=$build_root/pixman-prefix
artifact=$build_root/gamescope-${tag}-arm64-debian13.tar.zst
build_parent=$(dirname "$build_root")

if [[ -e "$build_root" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: build-root-exists:$build_root" >&2
    exit 1
fi

mkdir -p "$build_parent"
available_kib=$(df --output=avail "$build_parent" | tail -n 1 | tr -d ' ')
if (( available_kib < 2 * 1024 * 1024 )); then
    echo "M1892_GAMESCOPE_BUILD_FAIL: insufficient-space-kib:$available_kib" >&2
    exit 1
fi

mkdir -p "$build_root"
# Keep compiler diagnostics, generated Build-IDs and any retained source paths
# independent of the account and build directory.  Runtime data paths are set
# separately to their Debian locations below.
export SOURCE_DATE_EPOCH=$epoch
export LC_ALL=C
export TZ=UTC
path_map="-ffile-prefix-map=$build_root=/usr/src/m1892-gamescope -fdebug-prefix-map=$build_root=/usr/src/m1892-gamescope -fmacro-prefix-map=$build_root=/usr/src/m1892-gamescope"
export CFLAGS="${CFLAGS:+$CFLAGS }$path_map"
export CXXFLAGS="${CXXFLAGS:+$CXXFLAGS }$path_map"
git clone --depth 1 --branch "$wayland_tag" \
    https://gitlab.freedesktop.org/wayland/wayland.git "$wayland_source"
if [[ "$(git -C "$wayland_source" rev-parse HEAD)" != "$wayland_commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-wayland-commit" >&2
    exit 1
fi
meson setup "$wayland_build" "$wayland_source" \
    --buildtype=release \
    --prefix="$wayland_prefix" \
    --libdir=lib \
    -Dicon_directory=/usr/share/icons \
    -Ddocumentation=false \
    -Dtests=false \
    -Ddtd_validation=false
ninja -C "$wayland_build" -j"${M1892_GAMESCOPE_JOBS:-6}" install

git clone --depth 1 --branch "$wayland_protocols_tag" \
    https://gitlab.freedesktop.org/wayland/wayland-protocols.git \
    "$wayland_protocols_source"
if [[ "$(git -C "$wayland_protocols_source" rev-parse HEAD)" != \
        "$wayland_protocols_commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-wayland-protocols-commit" >&2
    exit 1
fi
PATH="$wayland_prefix/bin:$PATH" \
PKG_CONFIG_PATH="$wayland_prefix/lib/pkgconfig" \
meson setup "$wayland_protocols_build" "$wayland_protocols_source" \
    --buildtype=release \
    --prefix="$wayland_protocols_prefix" \
    -Dtests=false
ninja -C "$wayland_protocols_build" -j"${M1892_GAMESCOPE_JOBS:-6}" install

git clone --depth 1 --branch "$libdrm_tag" \
    https://gitlab.freedesktop.org/mesa/drm.git "$libdrm_source"
if [[ "$(git -C "$libdrm_source" rev-parse HEAD)" != "$libdrm_commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-libdrm-commit" >&2
    exit 1
fi
meson setup "$libdrm_build" "$libdrm_source" \
    --buildtype=release \
    --prefix="$libdrm_prefix" \
    --libdir=lib \
    -Dtests=false \
    -Dman-pages=disabled
ninja -C "$libdrm_build" -j"${M1892_GAMESCOPE_JOBS:-6}" install

git clone --depth 1 --branch "$xkbcommon_tag" \
    https://github.com/xkbcommon/libxkbcommon.git "$xkbcommon_source"
if [[ "$(git -C "$xkbcommon_source" rev-parse HEAD)" != "$xkbcommon_commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-xkbcommon-commit" >&2
    exit 1
fi
PATH="$wayland_prefix/bin:$PATH" \
PKG_CONFIG_PATH="$wayland_prefix/lib/pkgconfig" \
LD_LIBRARY_PATH="$wayland_prefix/lib" \
meson setup "$xkbcommon_build" "$xkbcommon_source" \
    --buildtype=release \
    --prefix="$xkbcommon_prefix" \
    --libdir=lib \
    -Dxkb-config-root=/usr/share/X11/xkb \
    -Dx-locale-root=/usr/share/X11/locale \
    -Denable-docs=false \
    -Denable-tools=false \
    -Denable-x11=false \
    -Denable-wayland=false \
    -Denable-xkbregistry=false \
    -Denable-bash-completion=false
ninja -C "$xkbcommon_build" -j"${M1892_GAMESCOPE_JOBS:-6}" install

git clone --depth 1 --branch "$pixman_tag" \
    https://gitlab.freedesktop.org/pixman/pixman.git "$pixman_source"
if [[ "$(git -C "$pixman_source" rev-parse HEAD)" != "$pixman_commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-pixman-commit" >&2
    exit 1
fi
meson setup "$pixman_build" "$pixman_source" \
    --buildtype=release \
    --prefix="$pixman_prefix" \
    --libdir=lib \
    -Dtests=disabled \
    -Ddemos=disabled
ninja -C "$pixman_build" -j"${M1892_GAMESCOPE_JOBS:-6}" install

# Gamescope 3.16.29's wlroots requires Wayland >= 1.24 while Debian 13 ships
# 1.23.  Build the pinned upstream ABI locally and give only this Gamescope
# package a private runtime path; do not replace Debian's system Wayland.
export PATH="$wayland_prefix/bin:$PATH"
export PKG_CONFIG_PATH="$wayland_protocols_prefix/share/pkgconfig:$pixman_prefix/lib/pkgconfig:$xkbcommon_prefix/lib/pkgconfig:$libdrm_prefix/lib/pkgconfig:$wayland_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$pixman_prefix/lib:$xkbcommon_prefix/lib:$libdrm_prefix/lib:$wayland_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CPATH="$wayland_protocols_prefix/include${CPATH:+:$CPATH}"

git clone --depth 1 --branch "$tag" https://github.com/ValveSoftware/gamescope.git "$source_dir"

if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$commit" ]]; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-commit" >&2
    exit 1
fi
[[ "$(git -C "$source_dir" show -s --format=%ct HEAD)" == "$epoch" ]] || {
    echo "M1892_GAMESCOPE_BUILD_FAIL: unexpected-commit-timestamp" >&2
    exit 1
}

git -C "$source_dir" submodule update --init --depth 1 \
    src/reshade \
    subprojects/libdisplay-info \
    subprojects/libliftoff \
    subprojects/vkroots \
    subprojects/wlroots \
    thirdparty/SPIRV-Headers

meson setup "$build_dir" "$source_dir" \
    --buildtype=release \
    --prefix=/usr/local \
    --force-fallback-for=vkroots,libliftoff,libseat \
    -Dc_link_args=-Wl,-rpath,/usr/local/lib/m1892-gamescope \
    -Dcpp_link_args=-Wl,-rpath,/usr/local/lib/m1892-gamescope \
    -Ddrm_backend=enabled \
    -Dinput_emulation=enabled \
    -Drt_cap=enabled \
    -Denable_openvr_support=false \
    -Denable_tests=false \
    -Dbenchmark=disabled \
    -Davif_screenshots=disabled

ninja -C "$build_dir" -j"${M1892_GAMESCOPE_JOBS:-6}"
DESTDIR="$stage_dir" meson install -C "$build_dir" --skip-subprojects

private_lib=$stage_dir/usr/local/lib/m1892-gamescope
install -d -m 0755 "$private_lib"
for library in client server cursor egl; do
    cp -a "$wayland_prefix/lib/libwayland-$library.so."* "$private_lib/"
done
# Gamescope links only the libdrm core.  Do not package unrelated AMDGPU,
# Radeon, Nouveau or Etnaviv helpers whose compiled data paths vary by host.
cp -a "$libdrm_prefix/lib/"libdrm.so.* "$private_lib/"
cp -a "$xkbcommon_prefix/lib/"libxkbcommon*.so.* "$private_lib/"
cp -a "$pixman_prefix/lib/"libpixman-1.so.* "$private_lib/"

grep -q 'sgsr' <("$build_dir/src/gamescope" --help 2>&1) || {
    echo "M1892_GAMESCOPE_BUILD_FAIL: sgsr-filter-absent" >&2
    exit 1
}
readelf -d "$stage_dir/usr/local/bin/gamescope" |
    grep -q '/usr/local/lib/m1892-gamescope' || {
        echo "M1892_GAMESCOPE_BUILD_FAIL: private-wayland-runpath-absent" >&2
        exit 1
    }
if grep -R -a -E -l '/home/[^/]+/|/root/' "$stage_dir" >/dev/null; then
    echo "M1892_GAMESCOPE_BUILD_FAIL: private-host-path-in-stage" >&2
    exit 1
fi
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -C "$stage_dir" -cf - usr/local | zstd -19 -T0 -o "$artifact"

(cd "$stage_dir" && find . -type f -print0 | sort -z | xargs -0 sha256sum) \
    >"$build_root/installed-files.sha256"
sha256sum "$artifact" | tee "$artifact.sha256"

echo "M1892_GAMESCOPE_BUILD_PASS"
echo "artifact=$artifact"
