#!/usr/bin/env bash
set -euo pipefail

tag=v0.8.4
commit=992103e4fb744897826de04ea00a2f71e7018214
patch_sha256=813e4c15445d6591a9c3aa93ac16afda5651a0a30d34527bc809f83f6e180ed9
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
patch_file=${M1892_MANGOAPP_PATCH:-$script_dir/../patches/mangohud/0001-msm-dpu-fdinfo-devfreq.patch}
battery_patch_sha256=8c5fcf65965db32f43f1e96458307e6447effbe25205e15cff37b00e8d8e32b7
battery_patch_file=${M1892_MANGOAPP_BATTERY_PATCH:-$script_dir/../patches/mangohud/0002-detect-battery-by-power-supply-type.patch}

if [[ "$(uname -m)" != "aarch64" ]]; then
    echo "M1892_MANGOAPP_BUILD_FAIL: native-aarch64-required" >&2
    exit 1
fi

for command in git meson ninja pkg-config c++ python3 tar zstd sha256sum file; do
    command -v "$command" >/dev/null || {
        echo "M1892_MANGOAPP_BUILD_FAIL: missing-command:$command" >&2
        exit 1
    }
done

python3 -c 'import mako' >/dev/null 2>&1 || {
    echo "M1892_MANGOAPP_BUILD_FAIL: missing-python-module:mako" >&2
    exit 1
}

for dependency in \
    dbus-1 glfw3 libcap libdrm vulkan wayland-client x11 xkbcommon; do
    pkg-config --exists "$dependency" || {
        echo "M1892_MANGOAPP_BUILD_FAIL: missing-pkgconfig:$dependency" >&2
        exit 1
    }
done

build_root=${M1892_MANGOAPP_BUILD_ROOT:-/home/$(id -un)/m1892-build/mangohud-${tag}-repro}
source_dir=$build_root/source
build_dir=$source_dir/build
stage_dir=$build_root/stage
artifact=$build_root/mangoapp-${tag}-arm64-debian13.tar.zst
build_parent=$(dirname "$build_root")

if [[ -e "$build_root" ]]; then
    echo "M1892_MANGOAPP_BUILD_FAIL: build-root-exists:$build_root" >&2
    exit 1
fi

mkdir -p "$build_parent"
available_kib=$(df --output=avail "$build_parent" | tail -n 1 | tr -d ' ')
if (( available_kib < 4 * 1024 * 1024 )); then
    echo "M1892_MANGOAPP_BUILD_FAIL: insufficient-space-kib:$available_kib" >&2
    exit 1
fi

mkdir -p "$build_root"
git clone --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
    https://github.com/flightlessmango/MangoHud.git "$source_dir"

if [[ "$(git -C "$source_dir" rev-parse HEAD)" != "$commit" ]]; then
    echo "M1892_MANGOAPP_BUILD_FAIL: unexpected-commit" >&2
    exit 1
fi

[[ -r "$patch_file" ]] || {
    echo "M1892_MANGOAPP_BUILD_FAIL: missing-patch:$patch_file" >&2
    exit 1
}
if [[ "$(sha256sum "$patch_file" | awk '{print $1}')" != "$patch_sha256" ]]; then
    echo "M1892_MANGOAPP_BUILD_FAIL: patch-hash" >&2
    exit 1
fi
git -C "$source_dir" apply --check "$patch_file"
git -C "$source_dir" apply "$patch_file"
[[ -r "$battery_patch_file" ]] || {
    echo "M1892_MANGOAPP_BUILD_FAIL: missing-patch:$battery_patch_file" >&2
    exit 1
}
if [[ "$(sha256sum "$battery_patch_file" | awk '{print $1}')" != "$battery_patch_sha256" ]]; then
    echo "M1892_MANGOAPP_BUILD_FAIL: battery-patch-hash" >&2
    exit 1
fi
git -C "$source_dir" apply --check "$battery_patch_file"
git -C "$source_dir" apply "$battery_patch_file"

meson setup "$build_dir" "$source_dir" \
    --buildtype=release \
    --prefix=/usr/local \
    --libdir=lib/aarch64-linux-gnu \
    -Dmangoapp=true \
    -Dmangohudctl=true \
    -Dwith_fex=true \
    -Dwith_nvml=disabled \
    -Dwith_xnvctrl=disabled \
    -Dwith_x11=enabled \
    -Dwith_wayland=enabled \
    -Dwith_dbus=enabled \
    -Dtests=disabled \
    -Dmangoplot=disabled

ninja -C "$build_dir" -j"${M1892_MANGOAPP_JOBS:-6}"
DESTDIR="$stage_dir" meson install -C "$build_dir" --skip-subprojects

mangoapp=$stage_dir/usr/local/bin/mangoapp
[[ -x "$mangoapp" ]] || {
    echo "M1892_MANGOAPP_BUILD_FAIL: mangoapp-not-installed" >&2
    exit 1
}
file "$mangoapp" | grep -q 'ARM aarch64' || {
    echo "M1892_MANGOAPP_BUILD_FAIL: mangoapp-not-aarch64" >&2
    exit 1
}

epoch=$(git -C "$source_dir" show -s --format=%ct "$commit")
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -C "$stage_dir" -cf - usr/local | zstd -19 -T0 -o "$artifact"

find "$stage_dir" -type f -print0 | sort -z | xargs -0 sha256sum \
    >"$build_root/installed-files.sha256"
sha256sum "$artifact" | tee "$artifact.sha256"

echo "M1892_MANGOAPP_BUILD_PASS"
echo "artifact=$artifact"
