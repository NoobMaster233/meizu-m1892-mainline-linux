# Proprietary firmware boundary

[简体中文](FIRMWARE.md) | **English**

`sudo` in this document means an owner-configured privilege tool. Minimal
Alpine may not include it; use a `su -` root shell for mount or loop-device
steps. Firmware extraction and `abuild` must still run as a regular user.

M1892 GPU, video, cellular, Wi-Fi, Bluetooth and sensor paths need
device-signed vendor firmware. These copyrighted files are not redistributable.
The project publishes only manifests/hashes, extraction and local-injection
source, package recipes, and open kernel/userspace changes.

The repository and Release **do not provide** a Flyme package or its members,
stock boot/recovery tails, a rootfs/initramfs containing vendor firmware, or
firmware copied from a development handset. Each owner must use their own
official Flyme 8.1.9.0A download. Generated material is local-only.

## Download and extract

Clone `qca-swiss-army-knife` at
`34fa4d6bd6641c79e6a6384816314fbbcd5a23cc`, then run:

```sh
./scripts/download-official-flyme.sh --check
./scripts/download-official-flyme.sh --download out/Flyme-8.1.9.0A-update.zip
export ATH10K_BDENCODER=/path/to/qca-swiss-army-knife/tools/scripts/ath10k/ath10k-bdencoder
./scripts/extract-flyme-firmware.sh out/Flyme-8.1.9.0A-update.zip \
  out/local-firmware out/m1892-firmware-runtime-20260831.tar.gz
```

The extractor reads official images without mounting, verifies all expected
members, and emits a 146-file manifest plus deterministic local archive. The
archive must match exactly:

```text
bytes   50161209
sha256  381d1873fcbac5d39e16ecd97fe2ccad214465748614cbccc49d21b6727e9133
sha512  474dbb8e25e8e38f9e1880b5310e830c51a71732bdcf0264b31b1bac092173ab5eea3f2ad599900e2bef1d5f73a04c456c36521edfdce5fd5c2cca670f0dd3dd
```

In Alpine with `alpine-sdk`, build as a regular user:

```sh
./scripts/build-local-firmware-apk.sh \
  out/m1892-firmware-runtime-20260831.tar.gz \
  out/firmware-meizu-m1892-20260831-r0.apk
./scripts/download-runtime-apks.sh out/alpine-rmtfs-1.3-r0-aarch64
```

The outer APK signature/metadata may vary with the local key, so the build and
verification scripts check package identity and every installed file instead of a whole
APK hash. Two open A630 files come from pinned linux-firmware tag `20260221`
and are recipe-verified, not copied from Flyme.

## Build local userdata

Verify and unpack the public base:

```sh
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
sudo env M1892_FIRMWARE_MODE=absent \
  ./scripts/verify-fresh-image.sh out/m1892-mainline-base.raw
```

Inject owner firmware and the pinned Alpine `rmtfs` packages:

```sh
RELEASE=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fLO "$RELEASE/m1892-telephony-audio-runtime.tar.gz"
curl -fLO "$RELEASE/m1892-telephony-audio-runtime.tar.gz.sha256"
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
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
```

Pinned Alpine package SHA-256 values:

```text
rmtfs-1.3-r0.apk         a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4
rmtfs-openrc-1.3-r0.apk  5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769
rmtfs-udev-1.3-r0.apk    09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7
```

Only the baseline build without an injected SSH public key has owner-local raw
SHA-256
`596b37a306397be06538705db979beed0747bf939745104fa0f452ac7bcc488f`;
its sparse SHA-256 is
`cc6025bed15d0c6043f657d0b2b8683cc54591cf31bd692f1239c151af426aab`.
Injecting any public key intentionally changes both hashes; use that build's
sidecar and strong verifier instead. Never redistribute a firmware-complete
image.

## Per-phone sensor calibration

Sensor calibration is not in Flyme `update.zip` and must not be copied between
devices. Run these only as root on the booted M1892, not on the build host:

```sh
/usr/local/sbin/m1892-persist-sensors-import --check
# After the check passes, install into this handset's rootfs if needed:
/usr/local/sbin/m1892-persist-sensors-import --install
```

The importer validates the device and partition, mounts this handset's
`persist` with `ro,noload`, and never writes that partition. `--install` writes
only the target directory in the running system.
