#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
tree_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
# shellcheck disable=SC1090
config=${M1892_STAGE3_CONFIG:-$tree_dir/config/stage3.env}
[ -r "$config" ] || { echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: unreadable-config' >&2; exit 2; }
config=$(readlink -f "$config")
M1892_DEBIAN_CONFIG_DIR=$(dirname "$config")
export M1892_DEBIAN_CONFIG_DIR
. "$config"
base=${1:-}
output_dir=${2:-}
source_recovery=${3:-}
live_user=${M1892_STAGE3_LIVE_USER:-m1892-live}
account_mode=${M1892_ACCOUNT_MODE:-}
local_nm_profile=${M1892_STAGE3_NM_PROFILE:-}
local_nm_type=none
local_authorized_key=${M1892_STAGE3_AUTHORIZED_KEY:-}
full_modules=${M1892_STAGE3_MODULES_DIR:-}
module_manifest=${M1892_STAGE3_MODULES_SHA256:-}
module_metadata=${M1892_STAGE3_MODULES_METADATA:-}
owner_firmware=${M1892_STAGE3_OWNER_FIRMWARE_DIR:-}
q6voiced_input=${M1892_STAGE3_Q6VOICED_DIR:-}
callaudiod_input=${M1892_STAGE3_CALLAUDIOD_DIR:-}
spacebar_input=${M1892_STAGE5_SPACEBAR_DIR:-}
ims_input=${M1892_STAGE5_IMS_DIR:-}
target_root_mode=${M1892_STAGE3_ROOT_MODE:-ram-loopback}
development_usb=${M1892_STAGE3_DEVELOPMENT_USB:-auto}
suspend_policy=${M1892_STAGE3_SUSPEND_POLICY:-masked}
[ -f "$base" ] && [ -n "$output_dir" ] && [ -f "$source_recovery" ] || {
	echo "usage: $0 STAGE3_ROOTFS_TAR ABSOLUTE_OUTPUT_DIR R545_RECOVERY" >&2
	exit 2
}
case "$output_dir" in /*) ;; *) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: output-not-absolute' >&2; exit 2 ;; esac
case "$target_root_mode" in
	ram-loopback|persistent-userdata-image) ;;
	*) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-root-mode' >&2; exit 2 ;;
esac
case "$account_mode:$target_root_mode" in
	recovery-live:ram-loopback|development-persistent:persistent-userdata-image|oem-owner:persistent-userdata-image) ;;
	*) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-account-root-mode' >&2; exit 2 ;;
esac
case "$account_mode" in
	recovery-live|development-persistent)
		case "$live_user" in ''|*[!a-z0-9_-]*)
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-live-user' >&2
			exit 2
			;; esac
		;;
	oem-owner)
		[ -z "${M1892_STAGE3_LIVE_USER:-}" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-live-user-override' >&2
			exit 2
		}
		[ -z "$local_nm_profile" ] && [ -z "$local_authorized_key" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-private-input' >&2
			exit 2
		}
		live_user=none
		;;
esac
case "$development_usb" in
	auto)
		case "$account_mode" in oem-owner) development_usb=no ;; *) development_usb=yes ;; esac
		;;
	yes|no) ;;
	*) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-development-usb' >&2; exit 2 ;;
esac
case "$account_mode:$target_root_mode:$suspend_policy" in
	recovery-live:ram-loopback:masked|\
	development-persistent:persistent-userdata-image:masked|\
	development-persistent:persistent-userdata-image:manual|\
	oem-owner:persistent-userdata-image:masked|\
	oem-owner:persistent-userdata-image:manual) ;;
	*) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-suspend-policy' >&2; exit 2 ;;
esac
if [ -n "$local_nm_profile" ]; then
	[ -f "$local_nm_profile" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: local-network-profile-absent' >&2
		exit 1
	}
	grep -Fxq '[connection]' "$local_nm_profile" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-local-network-profile' >&2
		exit 1
	}
	if grep -Fxq 'type=wifi' "$local_nm_profile" && grep -Fxq '[wifi]' "$local_nm_profile"; then
		local_nm_type=wifi
		if grep -Eq '^key-mgmt=(wpa-psk|sae)$' "$local_nm_profile"; then
			grep -Eq '^psk=.+$' "$local_nm_profile" || {
				echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: local-network-secret-absent' >&2
				exit 1
			}
		fi
	elif grep -Fxq 'type=gsm' "$local_nm_profile" && grep -Fxq '[gsm]' "$local_nm_profile"; then
		local_nm_type=gsm
	else
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-local-network-profile' >&2
		exit 1
	fi
fi
if [ -n "$local_authorized_key" ]; then
	[ "$account_mode" = development-persistent ] &&
		[ -f "$local_authorized_key" ] &&
		[ "$(wc -l <"$local_authorized_key")" = 1 ] &&
		grep -Eq '^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,3}( |$)' \
			"$local_authorized_key" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-local-authorized-key' >&2
		exit 1
	}
fi
case "${full_modules:+modules}:${module_manifest:+manifest}:${module_metadata:+metadata}" in
	::) ;;
	modules:manifest:metadata)
		[ -d "$full_modules" ] && [ -f "$module_manifest" ] &&
			[ -f "$module_metadata" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-input-absent' >&2
			exit 1
		}
		[ "$(basename "$full_modules")" = "$M1892_KERNEL_RELEASE" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-release' >&2
			exit 1
		}
		grep -Fxq "kernel_release=$M1892_KERNEL_RELEASE" "$module_metadata" &&
			grep -Fxq 'upstream_commit=85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8' \
				"$module_metadata" &&
			grep -Fxq 'compiler=aarch64-linux-gnu-gcc-11.4.0' "$module_metadata" &&
			grep -Fxq 'materialization_allowlist_sha256=2c37c4950402b9a784d517abfce1651e624575018f815f9d38729dc6fc872b22' "$module_metadata" &&
			grep -Fxq 'materialization_package_map_sha256=0732098beb21a357ec3a9f98c9db302d3d6086e58ba4b5d4a95154fbfa507c52' "$module_metadata" &&
			grep -Fxq 'venus_core_sha256=761cbe91ac41cc25e3b05e27bb9e0dcb07eb8a3fc8c58de188f586213231ac20' "$module_metadata" || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-metadata' >&2
			exit 1
		}
		[ "$(sha256sum "$module_manifest" | awk '{print $1}')" = \
			"$(sed -n 's/^module_manifest_sha256=//p' "$module_metadata")" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-manifest-hash' >&2
			exit 1
		}
		(cd "$full_modules" && sha256sum -c "$module_manifest") >/dev/null || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-content-hash' >&2
			exit 1
		}
		for module in kernel/fs/fuse/fuse.ko \
			kernel/drivers/gpu/drm/panel/panel-samsung-sofef00m.ko \
			kernel/drivers/media/platform/qcom/venus/venus-core.ko \
			kernel/drivers/net/wireless/ath/ath10k/ath10k_snoc.ko \
			kernel/drivers/remoteproc/qcom_q6v5_mss.ko; do
			[ -f "$full_modules/$module" ] || {
				echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: full-module-absent:$module" >&2
				exit 1
			}
		done
		;;
	*) echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: incomplete-full-module-inputs' >&2; exit 2 ;;
esac
if [ -n "$owner_firmware" ]; then
	[ -d "$owner_firmware/lib/firmware" ] &&
		[ -d "$owner_firmware/usr/share/qcom" ] &&
		[ -f "$owner_firmware/FIRMWARE-MANIFEST.tsv" ] &&
		[ -f "$owner_firmware/LOCAL-ONLY.txt" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-input-absent' >&2
		exit 1
	}
	[ "$(wc -l <"$owner_firmware/FIRMWARE-MANIFEST.tsv")" = 146 ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-manifest-count' >&2
		exit 1
	}
	[ "$(find "$owner_firmware/lib" "$owner_firmware/usr" -type f | wc -l)" = 146 ] &&
		! find "$owner_firmware/lib" "$owner_firmware/usr" -type l -print -quit |
			grep -q . || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-tree-closure' >&2
		exit 1
	}
	while IFS="$(printf '\t')" read -r expected_hash expected_size relative; do
		case "$relative" in
			lib/firmware/*|usr/share/qcom/*) ;;
			*) echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-path:$relative" >&2; exit 1 ;;
		esac
		file=$owner_firmware/$relative
		[ -f "$file" ] && [ ! -L "$file" ] || {
			echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-file:$relative" >&2
			exit 1
		}
		[ "$(stat -c %s "$file")" = "$expected_size" ] &&
			[ "$(sha256sum "$file" | awk '{print $1}')" = "$expected_hash" ] || {
			echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-firmware-hash:$relative" >&2
			exit 1
		}
	done <"$owner_firmware/FIRMWARE-MANIFEST.tsv"
fi
if [ -n "$q6voiced_input" ]; then
	[ -n "$owner_firmware" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: q6voiced-requires-owner-firmware' >&2
		exit 1
	}
	[ -x "$q6voiced_input/q6voiced" ] &&
		[ -f "$q6voiced_input/BUILD-METADATA.txt" ] &&
		[ -f "$q6voiced_input/SHA256SUMS" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: q6voiced-input-absent' >&2
		exit 1
	}
	grep -Fxq 'component=m1892-debian13-q6voiced' "$q6voiced_input/BUILD-METADATA.txt" &&
		grep -Fxq 'source_sha256=2881970f03fe009a62b6ef4b1cff68be9a968b8e89097664de9e1a3e35063ad4' "$q6voiced_input/BUILD-METADATA.txt" &&
		grep -Fxq 'compiler=aarch64-linux-gnu-gcc-11.4.0' "$q6voiced_input/BUILD-METADATA.txt" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: q6voiced-metadata' >&2
		exit 1
	}
	(cd "$q6voiced_input" && sha256sum -c SHA256SUMS) >/dev/null || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: q6voiced-hash' >&2
		exit 1
	}
fi
if [ -n "$callaudiod_input" ]; then
	[ -n "$owner_firmware" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: callaudiod-requires-owner-firmware' >&2
		exit 1
	}
	[ -x "$callaudiod_input/callaudiod" ] &&
		[ -f "$callaudiod_input/BUILD-METADATA.txt" ] &&
		[ -f "$callaudiod_input/SHA256SUMS" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: callaudiod-input-absent' >&2
		exit 1
	}
	grep -Fxq 'component=m1892-debian13-callaudiod' "$callaudiod_input/BUILD-METADATA.txt" &&
	grep -Fxq 'upstream_sha256=17070205024a4bb75016dad3cc132039dff28d9f3a40226eb283ae3a78ce0ecf' "$callaudiod_input/BUILD-METADATA.txt" &&
		grep -Fxq 'm1892_patch_sha256=ea056bb9d4f5e25417f381b9cde5a3a5d2fbadfeffd27c993575486115c96a2e' "$callaudiod_input/BUILD-METADATA.txt" &&
		grep -Fxq 'compiler=aarch64-linux-gnu-gcc-14.2.0' "$callaudiod_input/BUILD-METADATA.txt" &&
		grep -Fxq 'reproducible_local_ab=yes' "$callaudiod_input/BUILD-METADATA.txt" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: callaudiod-metadata' >&2
		exit 1
	}
	(cd "$callaudiod_input" && sha256sum -c SHA256SUMS) >/dev/null || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: callaudiod-hash' >&2
		exit 1
	}
fi
if [ -n "$spacebar_input" ]; then
	[ -x "$spacebar_input/spacebar-daemon" ] &&
		[ -f "$spacebar_input/BUILD-METADATA.txt" ] &&
		[ -f "$spacebar_input/SHA256SUMS" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: spacebar-input-absent' >&2
		exit 1
	}
	grep -Fxq 'component=m1892-debian13-spacebar-multi-bearer' \
		"$spacebar_input/BUILD-METADATA.txt" &&
		grep -Fxq 'upstream_commit=ba754af074303ace6016f6f7732ddf27a474cbec' \
		"$spacebar_input/BUILD-METADATA.txt" &&
		grep -Fxq 'patch_sha256=a1934c69533951ba751501e65791dbe02d557aa6bbdf36b2b934ad1abc7b0ab6' \
		"$spacebar_input/BUILD-METADATA.txt" &&
		grep -Fxq 'reproducible_local_ab=yes' "$spacebar_input/BUILD-METADATA.txt" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: spacebar-metadata' >&2
		exit 1
	}
	(cd "$spacebar_input" && sha256sum -c SHA256SUMS) >/dev/null || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: spacebar-hash' >&2
		exit 1
	}
fi
if [ -n "$ims_input" ]; then
	[ -x "$ims_input/usr/libexec/m1892/m1892-81voltd" ] &&
		[ -x "$ims_input/opt/m1892-modemmanager/sbin/ModemManager" ] &&
		[ -f "$ims_input/opt/m1892-openimsd/lib/girepository-1.0/Qmi-1.0.typelib" ] &&
		[ -f "$ims_input/BUILD-METADATA.txt" ] && [ -f "$ims_input/SHA256SUMS" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: ims-input-absent' >&2
		exit 1
	}
		grep -Fxq 'component=m1892-debian13-ims-runtime' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'provenance=clean-native' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_upstream=a7794dd6c8ac216a97dc5a931edab2dfc46eca2a' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_no_main_default_patch_sha256=17b9a34eb2e4cc804c9ae1d45959eb372c85a3b9f48a7fa00223c5136922a4a5' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_main_default_install=absent' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_stale_main_default_cleanup=present' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_ra_default_router_acceptance=disabled' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'voltd_link_address_dad=preserved' "$ims_input/BUILD-METADATA.txt" &&
			grep -Fxq 'qcom_imsd_upstream=fd15814d403c13caf874620e48abe83e39b9f4f8' "$ims_input/BUILD-METADATA.txt" &&
		grep -Fxq 'modemmanager_upstream=d776ea38d29ca472a12323c1d45002ee19a66f57' "$ims_input/BUILD-METADATA.txt" &&
		grep -Fxq 'reproducible_local_ab=yes' "$ims_input/BUILD-METADATA.txt" || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: ims-input-metadata' >&2
		exit 1
	}
	[ "$(sha256sum "$ims_input/SHA256SUMS" | awk '{print $1}')" = \
		"$(sed -n 's/^runtime_manifest_sha256=//p' "$ims_input/BUILD-METADATA.txt")" ] &&
		(cd "$ims_input" && sha256sum -c SHA256SUMS) >/dev/null || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: ims-input-hash' >&2
		exit 1
	}
fi
if [ "${M1892_STAGE3_FAKEROOT:-0}" != 1 ]; then
	command -v fakeroot >/dev/null 2>&1 || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: missing-command:fakeroot' >&2
		exit 1
	}
	if [ "$account_mode" = oem-owner ]; then
		exec fakeroot -- env M1892_STAGE3_FAKEROOT=1 "$0" "$@"
	else
		exec fakeroot -- env M1892_STAGE3_FAKEROOT=1 \
			M1892_STAGE3_LIVE_USER="$live_user" "$0" "$@"
	fi
fi
[ -f "$base.sha256" ] || { echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: base-sidecar-absent' >&2; exit 2; }
(cd "$(dirname -- "$base")" && sha256sum -c "$(basename -- "$base").sha256") >/dev/null || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: base-hash' >&2
	exit 1
}
[ ! -e "$output_dir" ] || { echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: output-exists' >&2; exit 1; }
for command in aarch64-linux-gnu-gcc cpio debugfs depmod e2fsck find gzip install ln \
	md5sum mkfs.ext4 mktemp python3 readlink sed sha256sum stat systemd-sysusers tar \
	strings touch truncate; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: missing-command:$command" >&2
		exit 1
	}
	done

work=$(mktemp -d /tmp/m1892-debian-stage3-image.XXXXXXXX)
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM
root=$work/root
mkdir -p "$root" "$output_dir"
tar --same-owner --numeric-owner --exclude='./dev/*' -xf "$base" -C "$root"
mkdir -p "$root/dev"
# Fail before kernel/runtime assembly if an old base lacks either SVG ABI.
# Maliit is Qt5 even though the Plasma shell is Qt6.
for qt_abi in qt5 qt6; do
	[ -f "$root/usr/lib/aarch64-linux-gnu/$qt_abi/plugins/imageformats/libqsvg.so" ] || {
		echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: $qt_abi-svg-imageformat-plugin-absent" >&2
		exit 1
	}
done
if [ -n "${M1892_PLASMA_SETTINGS_VERSION:-}" ]; then
	installed_plasma_settings=$(awk '
		$1 == "Package:" { package=$2 }
		$1 == "Version:" && package == "plasma-settings" { version=$2 }
		$1 == "Status:" && package == "plasma-settings" &&
			$0 == "Status: install ok installed" { installed=1 }
		END { if (installed) print version }
	' "$root/var/lib/dpkg/status")
	[ "$installed_plasma_settings" = "$M1892_PLASMA_SETTINGS_VERSION" ] || {
		echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: plasma-settings-version:$installed_plasma_settings" >&2
		exit 1
	}
fi
if awk 'BEGIN { RS="" } $0 ~ /(^|\n)Package: plasma-mobile-phone\n/ &&
		$0 ~ /\nStatus: install ok installed(\n|$)/ { found=1 } END { exit(found ? 0 : 1) }' \
		"$root/var/lib/dpkg/status"; then
	[ -n "$q6voiced_input" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: phone-image-without-m1892-q6voiced' >&2
		exit 1
	}
	[ -n "$callaudiod_input" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: phone-image-without-m1892-callaudiod' >&2
		exit 1
	}
	[ -n "$spacebar_input" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: phone-image-without-patched-spacebar' >&2
		exit 1
	}
	[ -n "$ims_input" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: phone-image-without-ims-runtime' >&2
		exit 1
	}
fi
reboot_fastboot_source=$tree_dir/../public-release/src/boot/reboot-fastboot.c
reboot_fastboot_sha=2b8eb06dcf71544e6ae7f189c37bd9bdd67c6f18e36d0fa44fa2e35814f989ba
[ -f "$reboot_fastboot_source" ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: reboot-fastboot-source-absent' >&2
	exit 1
}
install -d "$root/usr/libexec/m1892"
aarch64-linux-gnu-gcc -Os -static -s -Wl,--build-id=none \
	-o "$root/usr/libexec/m1892/reboot-fastboot" "$reboot_fastboot_source"
[ "$(sha256sum "$root/usr/libexec/m1892/reboot-fastboot" | awk '{print $1}')" = \
	"$reboot_fastboot_sha" ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: reboot-fastboot-build-hash' >&2
	exit 1
}

# The generic Debian artifact remains redistributable and owner-neutral.  The
# local Recovery image is the audited owner source for the exact kernel ABI,
# open-source modules and firmware extracted from this phone's official image.
# Install those modules into Debian's standard kmod tree before PID 1 starts;
# relying on the recovery initramfs' historical /lib/modules/m1892-* bridge
# made udev/module alias loading invisible to modprobe.
[ "$(sha256sum "$source_recovery" | awk '{print $1}')" = \
	"$M1892_STAGE3_SOURCE_RECOVERY_SHA256" ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: source-recovery-hash' >&2
	exit 1
}
[ "$(stat -c %s "$source_recovery")" = 67108864 ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: source-recovery-size' >&2
	exit 1
}
python3 - "$source_recovery" "$work/source-initramfs.gz" <<'PY'
import struct, sys
raw = open(sys.argv[1], 'rb').read()
if raw[:8] != b'ANDROID!':
    raise SystemExit('outer-magic')
oks, ors, ops = (struct.unpack_from('<I', raw, off)[0] for off in (8, 16, 36))
oro = ops + ((oks + ops - 1) // ops) * ops
inner = raw[oro:oro + ors]
if inner[:8] != b'ANDROID!':
    raise SystemExit('inner-magic')
iks, irs, ips = (struct.unpack_from('<I', inner, off)[0] for off in (8, 16, 36))
iro = ips + ((iks + ips - 1) // ips) * ips
open(sys.argv[2], 'wb').write(inner[iro:iro + irs])
PY
mkdir -p "$work/source-initramfs"
gzip -dc "$work/source-initramfs.gz" >"$work/source-initramfs.cpio"
(cd "$work/source-initramfs" && cpio -idm --quiet <"$work/source-initramfs.cpio")
source_module_dir=$work/source-initramfs/lib/modules/m1892-wifi
target_module_dir=$root/lib/modules/$M1892_KERNEL_RELEASE/extra/m1892
source_extractor=$work/source-initramfs/bin/m1892-fat16-mss-extract
mss_extractor_sha=091ed1ef39ac0f458b6787df3f1ff8834ad9a97652b8dca7d4b899303ea7a893
[ -x "$source_extractor" ] && [ "$(sha256sum "$source_extractor" | awk '{print $1}')" = \
	"$mss_extractor_sha" ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: source-mss-extractor' >&2
	exit 1
}
module_source=recovery-r545-subset
module_manifest_sha256=none
install -d "$root/lib/modules" "$root/lib/firmware"
if [ -n "$full_modules" ]; then
	cp -a "$full_modules" "$root/lib/modules/$M1892_KERNEL_RELEASE"
	find "$root/lib/modules/$M1892_KERNEL_RELEASE" -maxdepth 1 -type l \
		\( -name build -o -name source \) -delete
	install -D -m 0644 \
		"$tree_dir/rootfs-overlay/etc/modules-load.d/m1892-system.conf" \
		"$root/etc/modules-load.d/m1892-system.conf"
	module_source=public-clean-full
	module_manifest_sha256=$(sha256sum "$module_manifest" | awk '{print $1}')
else
	for module in qcom_pd_mapper.ko reset-qcom-pdc.ko qcom_q6v5_mss.ko \
		ath10k_snoc.ko; do
		[ -f "$source_module_dir/$module" ] || {
			echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: source-module-absent:$module" >&2
			exit 1
		}
	done
	install -d "$target_module_dir"
	for source_tree in "$work"/source-initramfs/lib/modules/m1892-*; do
		[ -d "$source_tree" ] || continue
		cp -a "$source_tree/." "$target_module_dir/"
	done
fi
cp -a "$work/source-initramfs/lib/firmware/." "$root/lib/firmware/"
owner_firmware_scope=source-recovery-subset
owner_firmware_manifest_sha256=none
if [ -n "$owner_firmware" ]; then
	cp -a "$owner_firmware/lib/firmware/." "$root/lib/firmware/"
	install -d "$root/usr/share/qcom"
	cp -a "$owner_firmware/usr/share/qcom/." "$root/usr/share/qcom/"
	owner_firmware_scope=owner-local-complete
	owner_firmware_manifest_sha256=$(sha256sum \
		"$owner_firmware/FIRMWARE-MANIFEST.tsv" | awk '{print $1}')
fi
install -d "$root/lib/firmware/qcom/sdm845/m1892"
ln -snf /lib/firmware/ath10k/WCN3990/hw1.0/wlanmdsp.mbn \
	"$root/lib/firmware/qcom/sdm845/m1892/wlanmdsp.mbn"
install -D -m 0755 "$source_extractor" \
	"$root/usr/libexec/m1892/m1892-fat16-mss-extract"
depmod -b "$root" -a "$M1892_KERNEL_RELEASE"

overlay=$tree_dir/rootfs-overlay
install -d "$root/etc/NetworkManager/conf.d" "$root/etc/modprobe.d" \
	"$root/etc/sddm.conf.d" \
	"$root/etc/systemd/system/hexagonrpcd.service.d" \
	"$root/etc/systemd/system/graphical.target.wants" \
	"$root/etc/systemd/system/multi-user.target.wants" \
	"$root/etc/xdg/autostart" "$root/usr/libexec/m1892"
install -D -m 0644 "$overlay/etc/skel/.config/kglobalshortcutsrc" \
	"$root/etc/skel/.config/kglobalshortcutsrc"
install -D -m 0644 "$overlay/etc/skel/.config/applications-blacklistrc" \
	"$root/etc/skel/.config/applications-blacklistrc"
install -D -m 0644 "$overlay/etc/skel/.config/kwinrulesrc" \
	"$root/etc/skel/.config/kwinrulesrc"
install -D -m 0644 \
	"$overlay/etc/wireplumber/wireplumber.conf.d/51-m1892-hifi-format.conf" \
	"$root/etc/wireplumber/wireplumber.conf.d/51-m1892-hifi-format.conf"
install -D -m 0644 \
	"$overlay/usr/lib/tmpfiles.d/m1892-cpufreq-boost.conf" \
	"$root/usr/lib/tmpfiles.d/m1892-cpufreq-boost.conf"
install -D -m 0644 "$overlay/etc/xdg/powerdevilrc" "$root/etc/xdg/powerdevilrc"
if [ "$target_root_mode" = persistent-userdata-image ]; then
	sed -e 's/rootfs_id=m1892-debian13-stage3-ram/rootfs_id=m1892-debian13-stage7-persistent/' \
		-e 's/root_mode=ram-loopback/root_mode=persistent-userdata/' \
		"$overlay/etc/m1892-stage3-rootfs-identity" >"$root/etc/m1892-rootfs-identity"
	chmod 0644 "$root/etc/m1892-rootfs-identity"
else
	install -m 0644 "$overlay/etc/m1892-stage3-rootfs-identity" \
		"$root/etc/m1892-rootfs-identity"
fi
printf 'account_mode=%s\n' "$account_mode" >>"$root/etc/m1892-rootfs-identity"
printf 'suspend_policy=%s\n' "$suspend_policy" >>"$root/etc/m1892-rootfs-identity"
if grep -q '^development_console=' "$root/etc/m1892-rootfs-identity"; then
	sed -i "s/^development_console=.*/development_console=$development_usb/" \
		"$root/etc/m1892-rootfs-identity"
else
	printf 'development_console=%s\n' "$development_usb" >>"$root/etc/m1892-rootfs-identity"
fi
install -m 0644 "$overlay/etc/NetworkManager/conf.d/80-m1892-stage2-usb.conf" \
	"$root/etc/NetworkManager/conf.d/80-m1892-stage3-usb.conf"
install -D -m 0755 "$overlay/usr/libexec/m1892/wifi-identity" \
	"$root/usr/libexec/m1892/wifi-identity"
install -D -m 0644 "$overlay/etc/systemd/system/m1892-wifi-identity.service" \
	"$root/etc/systemd/system/m1892-wifi-identity.service"
install -D -m 0644 \
	"$overlay/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf" \
	"$root/etc/systemd/system/NetworkManager.service.d/15-m1892-wifi-identity.conf"
install -D -m 0755 "$overlay/usr/libexec/m1892/wake-policy" \
	"$root/usr/libexec/m1892/wake-policy"
install -D -m 0644 "$overlay/etc/systemd/system/m1892-wake-policy.service" \
	"$root/etc/systemd/system/m1892-wake-policy.service"
install -D -m 0644 "$overlay/etc/udev/rules.d/92-m1892-wifi-wake.rules" \
	"$root/etc/udev/rules.d/92-m1892-wifi-wake.rules"
q6voiced_scope=absent
q6voiced_sha256=none
if [ -n "$q6voiced_input" ]; then
	install -m 0755 "$q6voiced_input/q6voiced" \
		"$root/usr/libexec/m1892/q6voiced"
	install -m 0644 "$overlay/etc/systemd/system/m1892-q6voiced.service" \
		"$root/etc/systemd/system/m1892-q6voiced.service"
	ln -s ../m1892-q6voiced.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-q6voiced.service"
	q6voiced_scope=m1892-debian-native
	q6voiced_sha256=$(sha256sum "$q6voiced_input/q6voiced" | awk '{print $1}')
fi
callaudiod_scope=absent
callaudiod_sha256=none
if [ -x "$root/usr/bin/callaudiod" ]; then
	callaudiod_scope=distribution
	callaudiod_sha256=$(sha256sum "$root/usr/bin/callaudiod" | awk '{print $1}')
fi
if [ -n "$callaudiod_input" ]; then
	install -m 0755 "$callaudiod_input/callaudiod" \
		"$root/usr/libexec/m1892/callaudiod"
	install -D -m 0644 \
		"$overlay/usr/share/dbus-1/services/org.mobian_project.CallAudio.service" \
		"$root/usr/share/dbus-1/services/org.mobian_project.CallAudio.service"
	callaudiod_scope=m1892-split-profile
	callaudiod_sha256=$(sha256sum "$callaudiod_input/callaudiod" | awk '{print $1}')
fi
spacebar_scope=distribution
spacebar_sha256=$(sha256sum \
	"$root/usr/lib/aarch64-linux-gnu/libexec/spacebar-daemon" | awk '{print $1}')
if [ -n "$spacebar_input" ]; then
	install -m 0755 "$spacebar_input/spacebar-daemon" \
		"$root/usr/lib/aarch64-linux-gnu/libexec/spacebar-daemon"
	spacebar_scope=m1892-multi-bearer
	spacebar_sha256=$(sha256sum "$spacebar_input/spacebar-daemon" | awk '{print $1}')
fi
ims_scope=absent
ims_runtime_manifest_sha256=none
ims_voltd_no_main_default_patch_sha256=none
ims_voltd_main_default_install=not-applicable
ims_voltd_stale_main_default_cleanup=not-applicable
ims_voltd_ra_default_router_acceptance=not-applicable
ims_voltd_link_address_dad=not-applicable
if [ -n "$ims_input" ]; then
	install -d "$root/opt" "$root/etc/NetworkManager/dispatcher.d" \
		"$root/etc/systemd/system/ModemManager.service.d"
	for component in m1892-openimsd m1892-modemmanager m1892-mm-libqmi; do
		cp -a "$ims_input/opt/$component" "$root/opt/"
	done
	install -m 0755 "$ims_input/usr/libexec/m1892/m1892-81voltd" \
		"$root/usr/libexec/m1892/m1892-81voltd"
	install -m 0755 "$overlay/usr/libexec/m1892/qcom-imsd" \
		"$root/usr/libexec/m1892/qcom-imsd"
	install -m 0644 "$overlay/etc/systemd/system/m1892-81voltd.service" \
		"$root/etc/systemd/system/m1892-81voltd.service"
	install -m 0644 "$overlay/etc/systemd/system/m1892-qcom-imsd.service" \
		"$root/etc/systemd/system/m1892-qcom-imsd.service"
	install -m 0644 \
		"$overlay/etc/systemd/system/ModemManager.service.d/20-m1892-ims-runtime.conf" \
		"$root/etc/systemd/system/ModemManager.service.d/20-m1892-ims-runtime.conf"
	install -m 0755 "$overlay/etc/NetworkManager/dispatcher.d/90-m1892-ims-online" \
		"$root/etc/NetworkManager/dispatcher.d/90-m1892-ims-online"
	ims_scope=$(sed -n 's/^provenance=//p' "$ims_input/BUILD-METADATA.txt")
	ims_runtime_manifest_sha256=$(sha256sum "$ims_input/SHA256SUMS" | awk '{print $1}')
	ims_voltd_no_main_default_patch_sha256=$(sed -n \
		's/^voltd_no_main_default_patch_sha256=//p' "$ims_input/BUILD-METADATA.txt")
	ims_voltd_main_default_install=$(sed -n \
		's/^voltd_main_default_install=//p' "$ims_input/BUILD-METADATA.txt")
	ims_voltd_stale_main_default_cleanup=$(sed -n \
		's/^voltd_stale_main_default_cleanup=//p' "$ims_input/BUILD-METADATA.txt")
	ims_voltd_ra_default_router_acceptance=$(sed -n \
		's/^voltd_ra_default_router_acceptance=//p' "$ims_input/BUILD-METADATA.txt")
	ims_voltd_link_address_dad=$(sed -n \
		's/^voltd_link_address_dad=//p' "$ims_input/BUILD-METADATA.txt")
	strings "$ims_input/usr/libexec/m1892/m1892-81voltd" |
		grep -Fxq '/proc/sys/net/ipv6/conf/%s/accept_ra_defrtr' || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: ims-voltd-ra-policy-binary' >&2
		exit 1
	}
	strings "$ims_input/usr/libexec/m1892/m1892-81voltd" |
		grep -Fxq 'Removed stale IMS main-table defaults from %s' || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: ims-voltd-route-cleanup-binary' >&2
		exit 1
	}
fi
if [ -n "$owner_firmware" ]; then
	persist_import=$tree_dir/../public-release/scripts/import-m1892-persist-sensors.sh
	ucm_source=$tree_dir/../public-release/src/runtime-inputs/m1892-userspace/ucm2
	[ -f "$persist_import" ] && [ -d "$ucm_source/Meizu/m1892" ] &&
		[ -d "$ucm_source/conf.d/sdm845" ] || {
		echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: owner-runtime-input-absent' >&2
		exit 1
	}
	install -m 0644 \
		"$overlay/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf" \
		"$root/etc/systemd/system/hexagonrpcd.service.d/10-m1892-sdsp.conf"
	install -m 0755 "$persist_import" \
		"$root/usr/libexec/m1892/import-persist-sensors"
	install -m 0644 "$overlay/etc/systemd/system/m1892-persist-sensors.service" \
		"$root/etc/systemd/system/m1892-persist-sensors.service"
	ln -s ../m1892-persist-sensors.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-persist-sensors.service"
	install -d "$root/usr/share/alsa/ucm2/Meizu/m1892" \
		"$root/usr/share/alsa/ucm2/conf.d/sdm845"
	install -m 0644 "$ucm_source/Meizu/m1892/HiFi.conf" \
		"$ucm_source/Meizu/m1892/VoiceCall.conf" \
		"$root/usr/share/alsa/ucm2/Meizu/m1892/"
	install -m 0644 "$ucm_source/conf.d/sdm845/Meizu-16thPlus-m1892.conf" \
		"$root/usr/share/alsa/ucm2/conf.d/sdm845/Meizu-16thPlus-m1892.conf"
	# PipeWire ACP probes a capture PCM immediately after enabling the verb.
	# Keep the already accepted TX6 microphone route in the HiFi verb lifetime
	# for Debian; the common postmarketOS UCM remains unchanged.
	install -m 0644 "$overlay/usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf" \
		"$root/usr/share/alsa/ucm2/Meizu/m1892/HiFi.conf"
	install -m 0755 "$overlay/usr/libexec/m1892/venus-selftest" \
		"$root/usr/libexec/m1892/venus-selftest"
	install -D -m 0644 "$overlay/etc/udev/rules.d/90-m1892-ssc-sensors.rules" \
		"$root/etc/udev/rules.d/90-m1892-ssc-sensors.rules"
	install -D -m 0644 "$overlay/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf" \
		"$root/etc/systemd/system/iio-sensor-proxy.service.d/10-m1892-ssc.conf"
	install -D -m 0644 "$overlay/etc/systemd/system/sddm.service.d/10-m1892-iio-sensor-proxy.conf" \
		"$root/etc/systemd/system/sddm.service.d/10-m1892-iio-sensor-proxy.conf"
	install -m 0755 "$overlay/usr/libexec/m1892/wait-sensor-ready" \
		"$root/usr/libexec/m1892/wait-sensor-ready"
	install -m 0755 "$overlay/usr/libexec/m1892/bluetooth-identity" \
		"$root/usr/libexec/m1892/bluetooth-identity"
	install -m 0644 "$overlay/etc/systemd/system/m1892-bluetooth-identity.service" \
		"$root/etc/systemd/system/m1892-bluetooth-identity.service"
	install -m 0644 "$overlay/etc/systemd/system/m1892-bluetooth-transport.service" \
		"$root/etc/systemd/system/m1892-bluetooth-transport.service"
	install -m 0644 "$overlay/etc/udev/rules.d/91-m1892-bluetooth-identity.rules" \
		"$root/etc/udev/rules.d/91-m1892-bluetooth-identity.rules"
	ln -s ../m1892-bluetooth-transport.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-bluetooth-transport.service"
	cellular_source=$tree_dir/../public-release/src/runtime-inputs/userspace/daily/m1892-cellular-prepare
	[ "$(sha256sum "$cellular_source" | awk '{print $1}')" = db0438a9e88b9d68356421211e177708a069ff58efdbc05d09668118ee052c0d ] || exit 1
	sed '\|/sys/fs/ext4/sda19/errors_count|d' "$cellular_source" >"$root/usr/libexec/m1892/cellular-prepare"
	chmod 0755 "$root/usr/libexec/m1892/cellular-prepare"
	[ "$(sha256sum "$root/usr/libexec/m1892/cellular-prepare" | awk '{print $1}')" = 935236a698103150a0cdb096b292f1ecf5490ff08b21fb5654dd6c34a8373cb1 ] || exit 1
	install -m 0644 "$overlay/etc/systemd/system/m1892-cellular-prepare.service" "$root/etc/systemd/system/m1892-cellular-prepare.service"
	install -D -m 0644 "$overlay/etc/systemd/system/ModemManager.service.d/10-m1892-cellular.conf" "$root/etc/systemd/system/ModemManager.service.d/10-m1892-cellular.conf"
	ln -s ../m1892-cellular-prepare.service "$root/etc/systemd/system/multi-user.target.wants/m1892-cellular-prepare.service"
fi
private_network_injected=no
private_network_profile_sha256=none
private_network_type=none
carrier_neutral_cellular_profile=absent
carrier_neutral_cellular_profile_sha256=none
if [ -n "$local_nm_profile" ]; then
	install -d -m 0700 "$root/etc/NetworkManager/system-connections"
	install -m 0600 "$local_nm_profile" \
		"$root/etc/NetworkManager/system-connections/m1892-local-test.nmconnection"
	private_network_injected=yes
	private_network_type=$local_nm_type
	private_network_profile_sha256=$(sha256sum "$local_nm_profile" | awk '{print $1}')
fi
for unit in m1892-stage3-acceptance.service m1892-stage3-acm-shell.service; do
	install -m 0644 "$overlay/etc/systemd/system/$unit" "$root/etc/systemd/system/$unit"
done
install -m 0644 "$overlay/etc/modprobe.d/m1892-radio-order.conf" \
	"$root/etc/modprobe.d/m1892-radio-order.conf"
for unit in m1892-radio-modules.service m1892-radio-online.service; do
	install -m 0644 "$overlay/etc/systemd/system/$unit" \
		"$root/etc/systemd/system/$unit"
	ln -s "../$unit" "$root/etc/systemd/system/multi-user.target.wants/$unit"
done
install -m 0644 "$overlay/etc/systemd/system/m1892-mpss-firmware.service" \
	"$root/etc/systemd/system/m1892-mpss-firmware.service"
if [ -z "$owner_firmware" ]; then
	ln -s ../m1892-mpss-firmware.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-mpss-firmware.service"
	install -D -m 0644 "$overlay/etc/systemd/system/m1892-radio-modules.service.d/10-runtime-mpss-extract.conf" \
		"$root/etc/systemd/system/m1892-radio-modules.service.d/10-runtime-mpss-extract.conf"
fi
if [ "$account_mode" != oem-owner ]; then
	ln -s ../m1892-stage3-acceptance.service \
		"$root/etc/systemd/system/graphical.target.wants/m1892-stage3-acceptance.service"
fi
if [ "$development_usb" = yes ]; then
	ln -s ../m1892-stage3-acm-shell.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-stage3-acm-shell.service"
fi
if [ "$target_root_mode" = persistent-userdata-image ]; then
	install -m 0755 "$overlay/usr/libexec/m1892/persistent-first-boot" \
		"$root/usr/libexec/m1892/persistent-first-boot"
	install -m 0644 "$overlay/etc/systemd/system/m1892-persistent-first-boot.service" \
		"$root/etc/systemd/system/m1892-persistent-first-boot.service"
	ln -s ../m1892-persistent-first-boot.service \
		"$root/etc/systemd/system/multi-user.target.wants/m1892-persistent-first-boot.service"
fi
development_ssh_key_injected=no
development_ssh_key_sha256=none
if [ -n "$local_authorized_key" ]; then
	install -d -m 0700 "$root/root/.ssh"
	install -m 0600 "$local_authorized_key" "$root/root/.ssh/authorized_keys"
	ln -s /usr/lib/systemd/system/ssh.service \
		"$root/etc/systemd/system/multi-user.target.wants/ssh.service"
	development_ssh_key_injected=yes
	development_ssh_key_sha256=$(sha256sum "$local_authorized_key" | awk '{print $1}')
fi
# Hibernation has no accepted storage/resume contract on M1892 and remains
# masked in every mode.  Only the explicit manual policy exposes systemd's
# standard s2idle path; automatic PowerDevil suspend is a later gate.
for target in hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
	ln -s /dev/null "$root/etc/systemd/system/$target"
done
case "$suspend_policy" in
	masked)
		for target in sleep.target suspend.target; do
			ln -s /dev/null "$root/etc/systemd/system/$target"
		done
		;;
	manual)
		install -D -m 0644 \
			"$overlay/etc/systemd/sleep.conf.d/50-m1892-s2idle.conf" \
			"$root/etc/systemd/sleep.conf.d/50-m1892-s2idle.conf"
		ln -s ../m1892-wake-policy.service \
			"$root/etc/systemd/system/multi-user.target.wants/m1892-wake-policy.service"
		;;
esac
if [ -e "$root/usr/lib/systemd/system/NetworkManager.service" ]; then
	nm_link=$root/etc/systemd/system/multi-user.target.wants/NetworkManager.service
	if [ -L "$nm_link" ]; then
		[ "$(readlink "$nm_link")" = /usr/lib/systemd/system/NetworkManager.service ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: unexpected-networkmanager-link' >&2
			exit 1
		}
	else
		ln -s /usr/lib/systemd/system/NetworkManager.service "$nm_link"
	fi
fi
if [ -e "$root/usr/lib/systemd/system/docker.service" ]; then
	install -m 0755 "$overlay/usr/libexec/m1892/docker-selftest" \
		"$root/usr/libexec/m1892/docker-selftest"
	install -m 0755 "$overlay/usr/libexec/m1892/stage6-acceptance" \
		"$root/usr/libexec/m1892/stage6-acceptance"
	install -m 0644 "$overlay/etc/systemd/system/m1892-stage6-acceptance.service" \
		"$root/etc/systemd/system/m1892-stage6-acceptance.service"
	if [ "$account_mode" != oem-owner ]; then
		ln -s ../m1892-stage6-acceptance.service \
			"$root/etc/systemd/system/graphical.target.wants/m1892-stage6-acceptance.service"
	fi
	for unit in containerd.service docker.service; do
		[ -e "$root/usr/lib/systemd/system/$unit" ] || {
			echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: daily-unit-absent:$unit" >&2
			exit 1
		}
		unit_link=$root/etc/systemd/system/multi-user.target.wants/$unit
		if [ -L "$unit_link" ]; then
			[ "$(readlink "$unit_link")" = "/usr/lib/systemd/system/$unit" ] || {
				echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: unexpected-daily-unit-link:$unit" >&2
				exit 1
			}
		else
			ln -s "/usr/lib/systemd/system/$unit" "$unit_link"
		fi
	done
fi
install -m 0644 "$overlay/etc/xdg/autostart/m1892-stage3-session-acceptance.desktop" \
	"$root/etc/xdg/autostart/m1892-stage3-session-acceptance.desktop"
for helper in cellular-acceptance stage3-acceptance stage3-session-acceptance; do
	install -m 0755 "$overlay/usr/libexec/m1892/$helper" "$root/usr/libexec/m1892/$helper"
done

case "$account_mode" in
	recovery-live|development-persistent)
		# Passwordless technical users belong only to explicit development modes.
		systemd-sysusers --root="$root" \
			--inline "g $live_user 1000" \
			--inline "u $live_user 1000 \"M1892 Development Live\" /home/$live_user /bin/bash" \
			--inline "m $live_user audio" \
			--inline "m $live_user video" \
			--inline "m $live_user input" \
			--inline "m $live_user render" \
			--inline "m $live_user netdev" \
			--inline "m $live_user bluetooth" >/dev/null
		if grep -q '^docker:' "$root/etc/group"; then
			systemd-sysusers --root="$root" --inline "m $live_user docker" >/dev/null
		fi
		sed -i "s|^$live_user:[^:]*:[^:]*:|$live_user:!*:20703:|" "$root/etc/shadow"
		install -d -m 0700 -o 1000 -g 1000 "$root/home/$live_user" \
			"$root/home/$live_user/.config"
		cat >"$root/etc/sddm.conf.d/90-m1892-stage3-live.conf" <<EOF
[Autologin]
User=$live_user
Session=plasma-mobile.desktop
Relogin=true
EOF
		cat >"$root/home/$live_user/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
		cat >"$root/home/$live_user/.config/powerdevilrc" <<'EOF'
[AC][Display]
LockBeforeTurnOffDisplay=false

[Battery][Display]
LockBeforeTurnOffDisplay=false

[LowBattery][Display]
LockBeforeTurnOffDisplay=false
EOF
		cat >"$root/home/$live_user/.config/kwalletrc" <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF
		install -m 0644 "$overlay/etc/skel/.config/kglobalshortcutsrc" \
			"$root/home/$live_user/.config/kglobalshortcutsrc"
		install -m 0644 "$overlay/etc/skel/.config/applications-blacklistrc" \
			"$root/home/$live_user/.config/applications-blacklistrc"
		install -m 0644 "$overlay/etc/skel/.config/kwinrulesrc" \
			"$root/home/$live_user/.config/kwinrulesrc"
		for file in kscreenlockerrc powerdevilrc kwalletrc applications-blacklistrc \
			kwinrulesrc; do
			chown 1000:1000 "$root/home/$live_user/.config/$file"
		done
		chown 1000:1000 "$root/home/$live_user/.config/kglobalshortcutsrc"
		;;
	oem-owner)
		for path in /usr/bin/calamares /usr/bin/pkexec /usr/bin/flock \
			/usr/lib/aarch64-linux-gnu/calamares/modules/users/module.desc \
			/usr/lib/aarch64-linux-gnu/calamares/modules/users/libcalamares_viewmodule_users.so \
			/usr/lib/aarch64-linux-gnu/calamares/modules/displaymanager/module.desc; do
			[ -e "$root$path" ] || {
				echo "M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-runtime-absent:$path" >&2
				exit 1
			}
		done
		install -D -m 0644 "$overlay/usr/lib/sysusers.d/m1892-oem-setup.conf" \
			"$root/usr/lib/sysusers.d/m1892-oem-setup.conf"
		systemd-sysusers --root="$root" \
			"$root/usr/lib/sysusers.d/m1892-oem-setup.conf" >/dev/null
		setup_uid=$(awk -F: '$1 == "m1892-setup" { print $3 }' "$root/etc/passwd")
		setup_gid=$(awk -F: '$1 == "m1892-setup" { print $4 }' "$root/etc/passwd")
		[ "$setup_uid" -lt 1000 ] && [ "$setup_gid" -lt 1000 ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-setup-id-range' >&2
			exit 1
		}
		install -d -m 0700 -o "$setup_uid" -g "$setup_gid" \
			"$root/var/lib/m1892-oem-setup" "$root/var/lib/m1892-oem-setup/.config"
		cat >"$root/var/lib/m1892-oem-setup/.config/plasmamobilerc" <<'EOF'
[InitialStart]
wizardRun=true
EOF
		cat >"$root/var/lib/m1892-oem-setup/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
		cat >"$root/var/lib/m1892-oem-setup/.config/powerdevilrc" <<'EOF'
[AC][Display]
LockBeforeTurnOffDisplay=false
[Battery][Display]
LockBeforeTurnOffDisplay=false
[LowBattery][Display]
LockBeforeTurnOffDisplay=false
EOF
		cat >"$root/var/lib/m1892-oem-setup/.config/kwalletrc" <<'EOF'
[Wallet]
Enabled=false
First Use=false
EOF
		install -m 0644 "$overlay/etc/skel/.config/kglobalshortcutsrc" \
			"$root/var/lib/m1892-oem-setup/.config/kglobalshortcutsrc"
		install -m 0644 "$overlay/etc/skel/.config/applications-blacklistrc" \
			"$root/var/lib/m1892-oem-setup/.config/applications-blacklistrc"
		install -m 0644 "$overlay/etc/skel/.config/kwinrulesrc" \
			"$root/var/lib/m1892-oem-setup/.config/kwinrulesrc"
		chown "$setup_uid:$setup_gid" "$root/var/lib/m1892-oem-setup/.config/"*
		cat >"$root/etc/sddm.conf.d/90-m1892-oem-account.conf" <<'EOF'
[Autologin]
User=m1892-setup
Session=plasma-mobile.desktop
Relogin=true
EOF
		install -D -m 0644 "$overlay/etc/xdg/autostart/m1892-oem-account-setup.desktop" \
			"$root/etc/xdg/autostart/m1892-oem-account-setup.desktop"
		install -D -m 0644 "$overlay/etc/polkit-1/rules.d/49-m1892-oem-setup.rules" \
			"$root/etc/polkit-1/rules.d/49-m1892-oem-setup.rules"
		install -D -m 0644 "$overlay/usr/share/polkit-1/actions/org.m1892.oem-account-setup.policy" \
			"$root/usr/share/polkit-1/actions/org.m1892.oem-account-setup.policy"
		cellular_profile=$tree_dir/../public-release/src/rootfs/fresh-overlay/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
		provider_db=$root/usr/share/mobile-broadband-provider-info/serviceproviders.xml
		provider_md5sums=$root/var/lib/dpkg/info/mobile-broadband-provider-info.md5sums
		[ -f "$provider_db" ] && [ -f "$provider_md5sums" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: mobile-provider-database-absent' >&2
			exit 1
		}
		provider_md5=$(awk '$2 == "usr/share/mobile-broadband-provider-info/serviceproviders.xml" { print $1 }' \
			"$provider_md5sums")
		[ "${#provider_md5}" = 32 ] &&
			[ "$(md5sum "$provider_db" | awk '{print $1}')" = "$provider_md5" ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: mobile-provider-database-hash' >&2
			exit 1
		}
		[ -f "$cellular_profile" ] &&
			[ "$(sha256sum "$cellular_profile" | awk '{print $1}')" = \
			edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0 ] || {
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: generic-cellular-profile-source' >&2
			exit 1
		}
		install -d -m 0700 "$root/etc/NetworkManager/system-connections"
		if find "$root/etc/NetworkManager/system-connections" -mindepth 1 -type f \
			! -name m1892-cellular.nmconnection -print -quit | grep -q .; then
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: unexpected-oem-network-profile' >&2
			exit 1
		fi
		install -m 0600 "$cellular_profile" \
			"$root/etc/NetworkManager/system-connections/m1892-cellular.nmconnection"
		carrier_neutral_cellular_profile=present
		carrier_neutral_cellular_profile_sha256=$(sha256sum "$cellular_profile" | awk '{print $1}')
		install -D -m 0644 "$overlay/usr/local/share/applications/m1892-oem-account-setup.desktop" \
			"$root/usr/local/share/applications/m1892-oem-account-setup.desktop"
		install -D -m 0644 "$overlay/usr/local/share/applications/calamares.desktop" \
			"$root/usr/local/share/applications/calamares.desktop"
		install -d "$root/usr/share/m1892"
		cp -a "$overlay/usr/share/m1892/calamares-oem" "$root/usr/share/m1892/"
		python3 - "$root/etc/passwd" "$root/etc/group" \
			"$root/usr/share/m1892/calamares-oem/modules/users.conf" <<'PY' || {
import json
import sys

def names(path):
    with open(path, encoding="utf-8") as stream:
        return {line.split(":", 1)[0] for line in stream if ":" in line}

with open(sys.argv[3], encoding="utf-8") as stream:
    text = stream.read()
section = text.split("\nuser:\n", 1)[1].split("\nhostname:\n", 1)[0]
line = next(line for line in section.splitlines() if line.startswith("  forbidden_names:"))
configured = json.loads(line.split(":", 1)[1].strip())
if len(configured) != len(set(configured)):
    raise SystemExit("duplicate forbidden owner name")
required = names(sys.argv[1]) | names(sys.argv[2]) | {"m1892-live"}
if set(configured) != required:
    missing = sorted(required - set(configured))
    extra = sorted(set(configured) - required)
    raise SystemExit(f"forbidden owner names mismatch: missing={missing} extra={extra}")
PY
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-forbidden-owner-names' >&2
			exit 1
		}
		ln -s /usr/share/calamares/qml "$root/usr/share/m1892/calamares-oem/qml"
		install -d "$root/usr/share/m1892/calamares-oem/branding/default"
		cp -a "$root/usr/share/calamares/branding/default/." \
			"$root/usr/share/m1892/calamares-oem/branding/default/"
		python3 - \
			"$root/usr/share/m1892/calamares-oem/branding/default/branding.desc" <<'PY' || {
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = {
    "windowExpanding:    normal": "windowExpanding:    fullscreen",
    "sidebar: widget": "sidebar: none",
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit(f"unexpected Calamares branding source: {old}")
    text = text.replace(old, new)
path.write_text(text, encoding="utf-8")
PY
			echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: oem-mobile-branding' >&2
			exit 1
		}
		for helper in oem-account-setup-launcher oem-calamares-wrapper \
			oem-owner-prepare oem-owner-finalize oem-setup-cleanup oem-setup-recover; do
			install -m 0755 "$overlay/usr/libexec/m1892/$helper" "$root/usr/libexec/m1892/$helper"
		done
		for unit in m1892-oem-setup-cleanup.service m1892-oem-setup-recovery.service; do
			install -m 0644 "$overlay/etc/systemd/system/$unit" \
				"$root/etc/systemd/system/$unit"
		done
		ln -s ../m1892-oem-setup-recovery.service \
			"$root/etc/systemd/system/multi-user.target.wants/m1892-oem-setup-recovery.service"
		;;
esac

# Plasma Mobile 6.3's record quick setting is incompatible with the Debian
# package set.  Use the standard system-wide KConfig layer for every account;
# do not copy this product setting into a fixed user's home directory.
install -D -m 0644 "$overlay/etc/xdg/plasmamobilerc" "$root/etc/xdg/plasmamobilerc"

# Debian's two System Settings launchers use the freedesktop icon name
# preferences-system, while the installed KF6 Breeze theme ships the artwork
# as systemsettings.svg.  Provide one XDG hicolor fallback alias instead of
# rewriting package-owned desktop files.
install -d -m 0755 "$root/usr/share/icons/hicolor/scalable/apps"
ln -s ../../../breeze/apps/48/systemsettings.svg \
	"$root/usr/share/icons/hicolor/scalable/apps/preferences-system.svg"
ln -snf /usr/lib/systemd/system/graphical.target "$root/etc/systemd/system/default.target"
if [ -z "$local_authorized_key" ]; then
	rm -f "$root/etc/systemd/system/multi-user.target.wants/ssh.service" \
		"$root/etc/systemd/system/multi-user.target.wants/sshd.service"
fi

source_date_epoch=1788739200
find "$root" -xdev -exec touch -h -d "@$source_date_epoch" {} +
image_bytes=${M1892_STAGE3_IMAGE_BYTES:-3221225472}
case "$image_bytes" in ''|*[!0-9]*)
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: invalid-image-size' >&2
	exit 2
	;; esac
[ "$image_bytes" -ge 3221225472 ] && [ "$image_bytes" -le 8589934592 ] &&
	[ $((image_bytes % 4194304)) -eq 0 ] || {
	echo 'M1892_DEBIAN_STAGE3_IMAGE_FAIL: image-size-out-of-policy' >&2
	exit 2
}
if [ "$target_root_mode" = persistent-userdata-image ]; then
	image=$work/m1892-debian13-stage7-userdata.ext4
	artifact_name=m1892-debian13-stage7-userdata.ext4.gz
	filesystem_uuid=de131892-0000-4000-8000-000000000007
	filesystem_label=M1892_DEB13
	stage_label=7-plasma-mobile-persistent-userdata
	case "$account_mode" in
		development-persistent)
			live_user_scope=persistent-development
			account_provider=development-sysusers
			account_state=development-autologin
			;;
		oem-owner)
			live_user_scope=none
			account_provider=calamares-oem-post-delivery
			account_state=awaiting-owner-creation
			;;
	esac
else
	image=$work/m1892-debian13-stage3-rootfs.ext4
	artifact_name=m1892-debian13-stage3-rootfs.ext4.gz
	filesystem_uuid=de131892-0000-4000-8000-000000000003
	filesystem_label=M1892_DEB13_S3
	stage_label=3-plasma-mobile-ram-root
	live_user_scope=recovery-ram-only
	account_provider=recovery-sysusers
	account_state=recovery-autologin
fi
case "$suspend_policy" in
	masked)
		case "$target_root_mode" in
			persistent-userdata-image) automatic_suspend=masked-development ;;
			ram-loopback) automatic_suspend=masked-recovery-only ;;
		esac
		;;
	manual) automatic_suspend=disabled-manual-only ;;
esac
case "$development_usb" in
	yes) development_console=acm-root-shell ;;
	no) development_console=disabled ;;
esac
truncate -s "$image_bytes" "$image"
E2FSPROGS_FAKE_TIME=$source_date_epoch mkfs.ext4 -q -F -m 0 \
	-L "$filesystem_label" -U "$filesystem_uuid" \
	-E lazy_itable_init=0,lazy_journal_init=0 -d "$root" "$image"
E2FSPROGS_FAKE_TIME=$source_date_epoch debugfs -w -R \
	"set_super_value hash_seed $filesystem_uuid" "$image" >/dev/null 2>&1
E2FSPROGS_FAKE_TIME=$source_date_epoch e2fsck -fn "$image" >"$output_dir/e2fsck.log" 2>&1

image_sha=$(sha256sum "$image" | awk '{print $1}')
artifact=$output_dir/$artifact_name
gzip -n -6 <"$image" >"$artifact"
sha=$(sha256sum "$artifact" | awk '{print $1}')
bytes=$(stat -c %s "$artifact")
printf '%s  %s\n' "$sha" "$(basename "$artifact")" >"$artifact.sha256"
cat >"$output_dir/BUILD-METADATA.txt" <<EOF
stage=$stage_label
base_sha256=$(awk 'NR == 1 { print $1 }' "$base.sha256")
rootfs_config_sha256=$(sha256sum "$config" | awk '{print $1}')
artifact_sha256=$sha
artifact_size=$bytes
root_mode=$target_root_mode
persistent_root_image_size=$image_bytes
persistent_root_image_sha256=$image_sha
filesystem_uuid=$filesystem_uuid
desktop=plasma-mobile
display_manager=sddm
initialstart_backend=distribution-default-hardware
orientation_startup_order=iio-before-sddm
settings_launcher=plasma-mobile-folio-user-blacklist
account_mode=$account_mode
account_provider=$account_provider
account_state=$account_state
live_user_scope=$live_user_scope
live_user_name=$live_user
persistent_storage_modified=no
owner_credentials_injected=no
private_network_injected=$private_network_injected
private_network_type=$private_network_type
private_network_profile_sha256=$private_network_profile_sha256
carrier_neutral_cellular_profile=$carrier_neutral_cellular_profile
carrier_neutral_cellular_profile_sha256=$carrier_neutral_cellular_profile_sha256
daily_packages=${M1892_DAILY_PACKAGES:-none}
development_console=$development_console
normal_boot_root_console=$development_console
plasma_settings_version=${M1892_PLASMA_SETTINGS_VERSION:-distribution}
development_ssh_key_injected=$development_ssh_key_injected
development_ssh_key_sha256=$development_ssh_key_sha256
automatic_suspend=$automatic_suspend
suspend_policy=$suspend_policy
kernel_release=$M1892_KERNEL_RELEASE
source_recovery_sha256=$M1892_STAGE3_SOURCE_RECOVERY_SHA256
mss_extractor_sha256=$mss_extractor_sha
owner_firmware_scope=$owner_firmware_scope
owner_firmware_manifest_sha256=$owner_firmware_manifest_sha256
owner_wlan_tqftp_link=present
q6voiced_scope=$q6voiced_scope
q6voiced_sha256=$q6voiced_sha256
callaudiod_scope=$callaudiod_scope
callaudiod_sha256=$callaudiod_sha256
spacebar_scope=$spacebar_scope
spacebar_sha256=$spacebar_sha256
ims_scope=$ims_scope
ims_runtime_manifest_sha256=$ims_runtime_manifest_sha256
ims_voltd_no_main_default_patch_sha256=$ims_voltd_no_main_default_patch_sha256
ims_voltd_main_default_install=$ims_voltd_main_default_install
ims_voltd_stale_main_default_cleanup=$ims_voltd_stale_main_default_cleanup
ims_voltd_ra_default_router_acceptance=$ims_voltd_ra_default_router_acceptance
ims_voltd_link_address_dad=$ims_voltd_link_address_dad
radio_runtime=debian-systemd
kernel_module_layout=standard-kmod-tree
kernel_module_source=$module_source
kernel_module_manifest_sha256=$module_manifest_sha256
EOF
echo "artifact=$artifact"
echo "artifact_size=$bytes"
echo "artifact_sha256=$sha"
echo "rootfs_image_size=$image_bytes"
echo "rootfs_image_sha256=$image_sha"
echo M1892_DEBIAN_STAGE3_IMAGE_BUILD_PASS
