# Quick start

[简体中文](QUICK_START.md) | **English**

This is the shortest audited path for the current developer preview. It cannot be
a one-click installer: required Flyme firmware is not redistributable and must
be extracted locally by each device owner.

> **This erases the phone.** The procedure wipes Android `userdata` and writes
> `boot`. It is only for an unlocked Meizu 16th Plus whose Fastboot product is
> exactly `M1892`. Verify owner-specific recovery material first. Never write
> GPT, NV, calibration, `persist`, `proinfo`, `bootbak`, or another phone's image.

## Recommended: compile-free Docker/Podman path

If the computer has flashing tools but no Alpine build environment, install
Docker or Podman and follow [GitHub Actions and compile-free
installation](ACTIONS_EN.md) with the public builder image matching this tag.
It downloads and verifies public base/boot, then locally generates and verifies
`m1892-userdata.sparse.img` and verified host-side flashing tools from the
owner's Flyme ZIP. Flyme, keys and outputs are never uploaded. The host still
needs a POSIX shell, Python 3, coreutils and Android Platform Tools; the exact
requirements and container command are in the preceding link.

After the container succeeds, continue at section 5. Sections 1–4 below are the
equivalent local Alpine path for users who want step-by-step auditability or do
not accept the privileged-container boundary.

## 1. Prepare an Alpine build host

Use Alpine Linux edge x86_64 with at least 35 GiB free on a native ext4
filesystem. WSL is supported only inside its Linux filesystem, not `/mnt/c`.

`sudo` below means a privilege tool already configured by the owner. Minimal
Alpine may not include it; use `su -` for package installation and mount-based
verification, then return to the regular user for downloads, source builds and
`abuild`.

```sh
sudo apk add alpine-sdk android-tools coreutils curl \
  e2fsprogs e2fsprogs-extra \
  findutils git gzip kmod python3 tar unzip util-linux zstd zerofree
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 {print $2}')
test "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -n1)" = 1.47.4
git clone https://github.com/NoobMaster233/meizu-m1892-mainline-linux.git
cd meizu-m1892-mainline-linux
git checkout 2026.09-developer-preview.17
mkdir out
```

Stop if the version check fails. Version 1.47.4 is the minimum; do not
downgrade to 1.47.3.

## 2. Download public images

```sh
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fLO "$release/m1892-mainline-base.raw.zst"
curl -fLO "$release/m1892-mainline-base.raw.zst.sha256"
curl -fLO "$release/m1892-mainline-boot.img"
curl -fLO "$release/m1892-mainline-boot.img.sha256"
curl -fLO "$release/m1892-public-kernel.tar.gz"
curl -fLO "$release/m1892-public-kernel.tar.gz.sha256"
curl -fLO "$release/m1892-telephony-audio-runtime.tar.gz"
curl -fLO "$release/m1892-telephony-audio-runtime.tar.gz.sha256"
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-mainline-boot.img.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
cp m1892-mainline-boot.img out/m1892-mainline-boot.img
cp m1892-mainline-boot.img.sha256 out/m1892-mainline-boot.img.sha256
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
```

Never flash `m1892-mainline-base.raw` directly; it intentionally lacks
vendor firmware. If the current Release does not contain that asset and its
sidecar, stop.

## 3. Build the owner-local firmware APK

```sh
./scripts/download-official-flyme.sh --download \
  out/Flyme-8.1.9.0A-update.zip
git clone https://github.com/qca/qca-swiss-army-knife.git out/qca-swiss-army-knife
git -C out/qca-swiss-army-knife checkout 34fa4d6bd6641c79e6a6384816314fbbcd5a23cc
export ATH10K_BDENCODER="$PWD/out/qca-swiss-army-knife/tools/scripts/ath10k/ath10k-bdencoder"
./scripts/extract-flyme-firmware.sh out/Flyme-8.1.9.0A-update.zip \
  out/local-firmware out/m1892-firmware-runtime-20260831.tar.gz
./scripts/build-local-firmware-apk.sh \
  out/m1892-firmware-runtime-20260831.tar.gz \
  out/firmware-meizu-m1892-20260831-r0.apk
./scripts/download-runtime-apks.sh out/alpine-rmtfs-1.3-r0-aarch64
```

Run this step as a regular user. Never upload the Flyme package, extracted
archive, or generated firmware APK.

## 4. Build and verify owner-local userdata

The fast path requires an **existing** owner SSH public key; never use a private
key and do not create a project-specific key. This provides an executable,
auditable administrator path after first boot.

```sh
OWNER_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub" # or an existing RSA/ECDSA/FIDO public key
test -s "$OWNER_PUBLIC_KEY"
export M1892_ROOT_AUTHORIZED_KEYS_FILE="$OWNER_PUBLIC_KEY"
export M1892_TELEPHONY_AUDIO_ARCHIVE="$PWD/m1892-telephony-audio-runtime.tar.gz"
./scripts/make-local-firmware-image.sh \
  out/m1892-mainline-base.raw \
  out/firmware-meizu-m1892-20260831-r0.apk \
  out/alpine-rmtfs-1.3-r0-aarch64 \
  m1892-public-kernel.tar.gz \
  out/m1892-userdata.raw
./scripts/verify-local-firmware-image.sh \
  out/m1892-userdata.raw \
  out/firmware-meizu-m1892-20260831-r0.apk \
  out/alpine-rmtfs-1.3-r0-aarch64 \
  m1892-public-kernel.tar.gz
sudo env M1892_FIRMWARE_MODE=complete \
  M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE="$M1892_ROOT_AUTHORIZED_KEYS_FILE" \
  ./scripts/verify-fresh-image.sh out/m1892-userdata.raw
./scripts/img2fullsimg.py \
  out/m1892-userdata.raw out/m1892-userdata.sparse.img
./scripts/img2fullsimg.py --verify-against \
  out/m1892-userdata.sparse.img out/m1892-userdata.raw
sha256sum out/m1892-userdata.sparse.img >out/m1892-userdata.sparse.img.sha256
```

Use the repository's all-RAW sparse converter. Regular `img2simg` emits
`DONT_CARE` regions and cannot prove that stale userdata is overwritten.

The same sparse supports 64-GB and 128-GB models. First boot validates
`/dev/sda19` and expands ext4 to the real userdata boundary.

## 5. Read-only check, then explicit flash

Boot the phone into Fastboot and connect it:

```sh
if [ -x out/tools/flash-m1892.sh ]; then
  flash_helper=out/tools/flash-m1892.sh # recommended container path
else
  flash_helper=./scripts/flash-m1892.sh # local repository path from sections 1-4
fi
"$flash_helper" --check \
  out/m1892-userdata.sparse.img out/m1892-mainline-boot.img
"$flash_helper" --flash ERASE-M1892-USERDATA \
  out/m1892-userdata.sparse.img out/m1892-mainline-boot.img
```

The helper deliberately stays in Fastboot. Run `fastboot reboot` afterward.
If Windows Fastboot loses the endpoint after every userdata chunk succeeds,
return to Fastboot and resume only the boot write:

```sh
"$flash_helper" --resume-boot FLASH-M1892-BOOT \
  out/m1892-mainline-boot.img
fastboot reboot
```

First boot is slow; connect Wi-Fi manually at the desktop. There is currently
no Android-style graphical account wizard. The prebuilt fast path uses ordinary
user `m1892`, but hardware services do not depend on that name. The graphical
session logs in automatically. Membership in the `docker` group grants
effective root-equivalent host control. Connect as administrator with
`ssh root@PHONE_LAN_ADDRESS`.

The carrier-neutral cellular profile may connect automatically and use data
after first boot. Remove the SIM first, or disable mobile data immediately at
the desktop, if the plan is unsuitable or roaming applies.

## 6. First-boot acceptance

Run these base acceptance commands first:

```sh
grep -Fx 'RELEASE_ID="2026.09-developer-preview.17"' /etc/m1892-release
test "$(findmnt -n -o SOURCE /)" = /dev/sda19
test "$(findmnt -n -o FSTYPE /)" = ext4
test "$(cat /sys/fs/ext4/sda19/errors_count)" = 0
m1892-daily-health
docker info >/dev/null
```

The Docker self-test creates temporary containers, a network, a volume, an
image and `/tmp` directories under names unique to this run, then removes them
on exit. Do not run it while important Docker workloads are active:

```sh
m1892-docker-selftest
```

Base acceptance requires a final `M1892_DAILY_HEALTH_OK`, a passing Docker
self-test, and attended checks that Wi-Fi, LTE, automatic rotation, display
blanking and wake all work. Calls and SMS have passed on only one carrier/SIM;
use another phone to test SMS in both directions, incoming/outgoing calls,
ringing, receiver, loudspeaker and both microphone directions. Stop daily use
and enter Fastboot for rollback as described in [Installation](INSTALL_EN.md)
if health fails, ext4/I/O/RCU errors appear, or the phone cannot wake after
blanking. Do not repeatedly force-boot a failing filesystem.

See [Installation](INSTALL_EN.md), [Build](BUILD_EN.md), and
[Known issues](KNOWN_ISSUES_EN.md) for the full contract.
