#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
tree_root=$(CDPATH='' cd -- "$script_dir/.." && pwd)
image=${1:-}
fail() { echo "M1892_PUBLIC_BASE_VERIFY_FAIL: $*" >&2; exit 1; }
[ -z "${E2FSPROGS_DIR:-}" ] || PATH=$E2FSPROGS_DIR:$PATH
export PATH
[ -f "$image" ] || fail missing-image
[ "$(stat -c %s "$image")" = 8589934592 ] || fail image-size
for command in awk cpio debugfs e2fsck find grep gzip sha256sum sort stat tune2fs zerofree zstd; do
	command -v "$command" >/dev/null 2>&1 || fail "missing-command:$command"
done
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 { print $2 }')
[ "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -1)" = 1.47.4 ] ||
	fail "e2fsprogs-too-old:$e2fs_version"

work=$(mktemp -d "${TMPDIR:-/tmp}/m1892-public-base-verify.XXXXXX")
cleanup() { find "$work" -depth -delete 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

e2fsck -fn "$image" >/dev/null || fail filesystem
! tune2fs -l "$image" | grep '^Filesystem features:.*\borphan_file\b' >/dev/null ||
	fail orphan-file-feature
zero_report=$(zerofree -n -v "$image" 2>/dev/null | tr -d '\r')
[ "${zero_report%%/*}" = 0 ] || fail "nonzero-free-blocks:$zero_report"
debugfs -R "dump -p /lib/apk/db/installed $work/installed" "$image" >/dev/null 2>&1 ||
	fail apk-database
! grep -qx 'P:firmware-meizu-m1892' "$work/installed" || fail old-firmware-package
debugfs -R "dump -p /etc/passwd $work/passwd" "$image" >/dev/null 2>&1 || fail passwd
user_record=$(awk -F: '
	$3 >= 1000 && $3 != 65534 && $6 ~ "^/home/" && $7 !~ /(nologin|false)$/ {
		print; count++
	}
	END { if (count != 1) exit 1 }
' "$work/passwd") || fail regular-user-count
user_name=$(printf '%s\n' "$user_record" | cut -d: -f1)
user_home=$(printf '%s\n' "$user_record" | cut -d: -f6)
case $user_home in /home/*) ;; *) fail invalid-user-home ;; esac

debugfs -R "dump -p /etc/group $work/group" "$image" >/dev/null 2>&1 || fail group
awk -F: -v user="$user_name" '$1=="docker" {
	n=split($4, members, ","); for (i=1; i<=n; i++) if (members[i]==user) ok=1
} END { exit ok ? 0 : 1 }' "$work/group" || fail docker-group-membership

check_metadata()
{
	path=$1 expected_mode=$2
	debugfs -R "stat $path" "$image" >"$work/stat" 2>&1 ||
		fail "metadata-missing:$path"
	grep -q "Mode:  $expected_mode" "$work/stat" ||
		fail "metadata-mode:$path"
	grep -Eq 'User:[[:space:]]+0[[:space:]]+Group:[[:space:]]+0' "$work/stat" ||
		fail "metadata-owner:$path"
}
for path in / /etc /home /usr /etc/dconf /usr/bin /usr/local; do
	check_metadata "$path" 0755
done
fresh_metadata=$tree_root/src/rootfs/fresh-overlay-metadata.tsv
runtime_contract=$tree_root/src/runtime/SOURCE_FILES.tsv
[ -r "$fresh_metadata" ] || fail missing-fresh-overlay-metadata
[ -r "$runtime_contract" ] || fail missing-runtime-contract
tab=$(printf '\t')
while IFS="$tab" read -r target mode; do
	case $target in ''|'#'*) continue ;; esac
	check_metadata "$target" "$mode"
done <"$fresh_metadata"
while IFS="$tab" read -r source target mode component; do
	case $source in ''|'#'*) continue ;; esac
	# The redistributable base deliberately excludes files added while generating
	# an owner's local image. The
	# owner builder injects the current policy, telephony routing and speaker
	# modules; its final verifier checks every byte and mode independently.
	case $component in owner-overlay|speaker-kernel|telephony-audio) continue ;; esac
	check_metadata "$target" "$mode"
done <"$runtime_contract"

for package in libpathrs runc containerd containerd-openrc libxtables iptables \
	iptables-openrc tini-static docker-engine docker-cli docker-cli-buildx \
	docker-cli-compose docker docker-openrc docker-bash-completion log_proxy; do
	grep -qx "P:$package" "$work/installed" || fail "docker-package:$package"
done
debugfs -R "dump -p /etc/apk/world $work/world" "$image" >/dev/null 2>&1 ||
	fail apk-world
for package in docker docker-cli-buildx docker-cli-compose; do
	grep -qx "$package" "$work/world" || fail "docker-world:$package"
done
debugfs -R 'stat /etc/runlevels/default/docker' "$image" >"$work/stat" 2>&1 ||
	fail docker-service
grep -q 'Type: symlink' "$work/stat" || fail docker-service-type
grep -q 'Fast link dest: "/etc/init.d/docker"' "$work/stat" ||
	fail docker-service-target
check_metadata /etc/init.d/docker 0755
check_metadata /usr/bin/docker 0755
check_metadata /usr/bin/dockerd 0755

check_content_hash()
{
	path=$1 expected=$2
	current=$work/content
	debugfs -R "dump -p $path $current" "$image" >/dev/null 2>&1 ||
		fail "payload-missing:$path"
	actual=$(sha256sum "$current" | awk '{print $1}')
	[ "$actual" = "$expected" ] || fail "payload-hash:$path:$actual"
}
# Package names in /lib/apk/db/installed are not sufficient evidence that apk
# payloads exist. These were the exact historical omissions that made Docker
# appear installed while iptables, Compose and Buildx were unusable.
check_content_hash /usr/lib/xtables/libxt_addrtype.so \
	89d1a0ed121523af125963471773d95ccaa506ba62da97d95f30bc4a80ca41d8
check_content_hash /usr/libexec/docker/cli-plugins/docker-buildx \
	00f936b316ec852d77522f9843ac1d75d5130487f20e1ab2ab42ec4147acd82f
check_content_hash /usr/libexec/docker/cli-plugins/docker-compose \
	633746d8bbc3b1e3690628a73d2576545a8889960d23ca57edb9dc65b25f161e
check_content_hash /usr/sbin/tini-static \
	26080e123ce9781c576ce2dd15ba8922ae6c49718214414004d7cb10180245e9
check_content_hash /etc/containerd/config.toml \
	a804c1487a85e9ae0260c803565a46ab1b8d465e6101ddf97724e8377d5bbdfa

absent()
{
	path=$1
	debugfs -R "stat $path" "$image" >"$work/stat" 2>&1 || true
	grep -q 'File not found' "$work/stat" || fail "proprietary-path:$path"
}
for path in \
	/etc/machine-id \
	/var/lib/dbus/machine-id \
	$user_home/.ssh \
	/root/.ssh \
	/usr/lib/firmware/qcom/a630_gmu.bin \
	/usr/lib/firmware/qcom/a630_sqe.fw \
	/usr/lib/firmware/qcom/sdm845/m1892/a630_zap.mbn \
	/usr/lib/firmware/qcom/sdm845/m1892/modem.mbn \
	/usr/lib/firmware/qcom/venus-5.2/venus.mbn \
	/usr/share/qcom/sdm845/Meizu/m1892/dsp/sdsp/fastrpc_shell_2 \
	/usr/share/qcom/sdm845/Meizu/m1892/sensors/registry/icm206xx_0_platform.config; do
	absent "$path"
done
# Speaker modules are public GPL artifacts, but they must still be absent from
# this generic base: the owner builder installs modules produced by the exact
# same kernel bundle as Image.gz and the product DTB.  Reject both current and
# historical names so a stale prebuilt module cannot survive into a release.
for path in \
	/usr/lib/m1892/speaker/cs_dsp.ko \
	/usr/lib/m1892/speaker/snd-soc-wm-adsp.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-lib.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-spi.ko \
	/usr/lib/m1892/speaker/snd-soc-sdm845.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-lib-r442.ko \
	/usr/lib/m1892/speaker/snd-soc-cs35l41-r442.ko \
	/usr/lib/m1892/speaker/snd-soc-sdm845-r437.ko; do
	absent "$path"
done

debugfs -R 'ls -p /etc/ssh' "$image" >"$work/list" 2>/dev/null || true
! grep -q '/ssh_host_' "$work/list" || fail ssh-host-key
check_metadata /etc/NetworkManager/system-connections 0700
profile=/etc/NetworkManager/system-connections/m1892-cellular.nmconnection
check_metadata "$profile" 0600
debugfs -R "dump -p $profile $work/cellular" "$image" >/dev/null 2>&1 ||
	fail generic-cellular-profile
[ "$(sha256sum "$work/cellular" | awk '{print $1}')" = \
	edbb116493aaf4130cac3d1b6a8c9a26ec7fa151c70c96cffcf0aad23150fdb0 ] ||
	fail generic-cellular-profile-content
debugfs -R 'ls -p /etc/NetworkManager/system-connections' "$image" \
	>"$work/list" 2>/dev/null || fail network-profile-directory
[ "$(grep -Ev '/\.\.?//$|/m1892-cellular\.nmconnection/' "$work/list" || true)" = '' ] ||
	fail extra-network-profile

sensor_source=$tree_root/src/runtime-inputs/userspace/daily/m1892-sensors
daily_source=$tree_root/src/userspace/daily
first_boot_source=$tree_root/src/rootfs/fresh-overlay/etc/init.d/m1892-r6-first-boot
[ -r "$sensor_source" ] || fail missing-sensor-source
[ -d "$daily_source" ] || fail missing-daily-runtime-source
[ -r "$first_boot_source" ] || fail missing-first-boot-source
for spec in \
	"/usr/local/sbin/m1892-persist-sensors-import:$tree_root/scripts/import-m1892-persist-sensors.sh" \
	"/usr/local/sbin/m1892-sensors:$sensor_source" \
	"/usr/local/sbin/m1892-daily-health:$daily_source/m1892-daily-health" \
	"/usr/local/sbin/m1892-docker-selftest:$daily_source/m1892-docker-selftest" \
	"/etc/init.d/m1892-r6-first-boot:$first_boot_source" \
	"/etc/init.d/m1892-sensors:$daily_source/m1892-sensors.openrc"; do
	target=${spec%%:*}
	source=${spec#*:}
	debugfs -R "dump -p $target $work/current" "$image" >/dev/null 2>&1 || fail "missing:$target"
	[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
	  "$(sha256sum "$source" | awk '{print $1}')" ] || fail "content:$target"
	rm -f "$work/current"
	debugfs -R "stat $target" "$image" >"$work/stat" 2>&1
	grep -q 'Mode:  0755' "$work/stat" || fail "mode:$target"
done
grep -q 'registry/sns_reg_config' "$tree_root/scripts/import-m1892-persist-sensors.sh" ||
	fail persist-import-sns-reg-map

radio_order_source=$tree_root/src/runtime-inputs/userspace/daily/m1892-radio-order.conf
[ -f "$radio_order_source" ] || radio_order_source=$daily_source/m1892-radio-order.conf
[ -f "$radio_order_source" ] || fail missing-radio-order-source
debugfs -R "dump -p /etc/modprobe.d/m1892-radio-order.conf $work/current" \
	"$image" >/dev/null 2>&1 || fail missing-radio-order
[ "$(sha256sum "$work/current" | awk '{print $1}')" = \
  "$(sha256sum "$radio_order_source" | awk '{print $1}')" ] || fail radio-order-content
rm -f "$work/current"

debugfs -R "dump -p /etc/m1892-fresh-image $work/marker" "$image" >/dev/null 2>&1 || fail marker
grep -qx 'format=m1892-public-base-v1' "$work/marker" || fail marker-format
grep -qx 'role=unpersonalized-owner-build-input' "$work/marker" || fail marker-role
grep -qx 'root_uuid=3982b874-0ec0-57c4-a83b-37965b6be709' "$work/marker" || fail marker-uuid
grep -qx 'privacy=absent-machine-id,no-host-keys,no-user-keys,no-user-network-credentials,generic-cellular-autoconfig-only' \
	"$work/marker" || fail marker-privacy

for name in initramfs initramfs-extra; do
	debugfs -R "dump -p /boot/$name $work/$name" "$image" >/dev/null 2>&1 || fail "boot-file:$name"
	case $name in
	initramfs) zstd -dc "$work/$name" ;;
	initramfs-extra) gzip -dc "$work/$name" ;;
	esac | cpio -it 2>/dev/null >"$work/$name.list"
	! grep -Eq 'qcom/sdm845/(m1892|Meizu/m1892)|qcom/venus-5.2|ath10k/WCN3990|qca/m1892' \
		"$work/$name.list" || fail "proprietary-initramfs:$name"
done

echo "image_sha256=$(sha256sum "$image" | awk '{print $1}')"
echo M1892_PUBLIC_BASE_VERIFY_PASS
