# Installation

[简体中文](INSTALL.md) | **English**

The current version is a developer preview. It inherits evidence for a fresh
install, growth, desktop, Wi-Fi/LTE, a second cold boot and the automated
health suite on one 128-GB device. This does not mean every current artifact
received an equivalent full hardware campaign, and independent second-device
acceptance and a real 64-GB-device acceptance are still missing.

## Prerequisites

1. An unlocked Meizu 16th Plus whose Fastboot product is exactly `M1892`.
2. Verified personal stock boot/recovery and device-unique NV, calibration and
   unbrick backups.
3. Google Android platform-tools, temporary space on a native Linux filesystem
   and e2fsprogs 1.47.4 or newer.
4. Your own official Flyme 8.1.9.0A download. Never use another owner's
   extracted firmware or userdata.

This project neither unlocks the bootloader nor redistributes stock partitions
or proprietary Flyme firmware.

## Partitions written

Only:

```text
userdata  postmarketOS ext4 root (all Android user data is erased)
boot      M1892 EDK2 plus mainline Linux boot
```

The script never writes recovery, GPT, modem/NV, calibration, `persist`,
`proinfo`, `bootbak` or any other partition.

## Build owner-local userdata

Verify the compressed-image and public-kernel-bundle sidecars published in the
Release, then decompress and verify the raw result against the pinned hash:

```sh
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
```

The raw must be 8,589,934,592 bytes with SHA-256
`dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`.
Build the firmware APK from your own Flyme package as documented in
[Firmware](FIRMWARE_EN.md), then run:

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
```

The fast path requires an existing owner **public** key, never a private key;
do not create a project-specific key. Root and regular-user password login
remain locked. The public base and source archive contain no owner key; only
the locally generated userdata receives it.

Convert to Android sparse and compare every logical byte with the source raw:

```sh
./scripts/img2fullsimg.py \
  out/m1892-userdata.raw out/m1892-userdata.sparse.img
./scripts/img2fullsimg.py --verify-against \
  out/m1892-userdata.sparse.img out/m1892-userdata.raw
sha256sum out/m1892-userdata.sparse.img >out/m1892-userdata.sparse.img.sha256
```

The converter emits RAW chunks only, so every stale userdata byte is replaced.
Do not substitute ordinary `img2simg`, which emits `DONT_CARE` regions. The
streaming comparison avoids another 8-GiB round-trip file. Never flash the
firmware-free base directly.

## Read-only preflight

```sh
./scripts/flash-m1892.sh --check \
  out/m1892-userdata.sparse.img \
  out/m1892-mainline-boot.img
```

It checks one device, exact product, unlock state, an 8-GiB all-RAW sparse,
64-MiB boot and both sidecars. It writes nothing and does not reboot.

## Flash and resume

```sh
./scripts/flash-m1892.sh \
  --flash ERASE-M1892-USERDATA \
  out/m1892-userdata.sparse.img \
  out/m1892-mainline-boot.img
```

The script writes userdata first, then boot, and leaves the phone in Fastboot.
Windows Fastboot may lose the endpoint after every userdata transfer chunk succeeds.
Re-enter Fastboot and resume boot only:

```sh
./scripts/flash-m1892.sh \
  --resume-boot FLASH-M1892-BOOT \
  out/m1892-mainline-boot.img
fastboot reboot
```

## First boot and account

First boot verifies the model, `/dev/sda19` partition number/name, release
UUID and minimum 8-GiB size, then grows ext4 online to the actual userdata
boundary. The same sparse therefore supports both 64-GB and 128-GB models.

A full source build should select the account before `pmbootstrap install`
with standard `pmbootstrap config user` and `pmbootstrap config hostname`.
The prebuilt-base fast path contains the default regular account `m1892`, but
hardware services never use that name as a runtime anchor; they discover the
actual graphical session. There is no Android-style graphical account wizard.
The graphical session logs in automatically. Membership in the `docker` group
grants effective root-equivalent host control. The administrator path is the
public key injected at build time: `ssh root@PHONE_LAN_ADDRESS`.

Connect Wi-Fi manually on the first desktop. Installation acceptance requires
authorized-shell evidence for health, expansion, Wi-Fi/LTE and restart/suspend.

## Rollback

Before installation, obtain stock boot/recovery and unique unbrick material
from **this handset**, then preserve their hashes offline:

```sh
sha256sum owner-stock-boot.img owner-stock-recovery.img >owner-stock.sha256
sha256sum -c owner-stock.sha256
```

This project has no universal unprivileged backup tool and cannot reconstruct
NV/calibration from public assets. Roll back only while those hashes still
match and Fastboot reports product `M1892`:

```sh
fastboot getvar product
fastboot flash boot owner-stock-boot.img
fastboot flash recovery owner-stock-recovery.img
fastboot reboot recovery
```

Let stock recovery rebuild Android userdata. Never use another handset's
images. Without verified owner backups, stop before installation rather than
treating the public Release as an unbrick package.
