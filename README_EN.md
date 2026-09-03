# Meizu 16th Plus (M1892) mainline Linux

[简体中文](README.md) | **English**

Experimental postmarketOS/Phosh and mainline-Linux port for the Meizu 16th
Plus (`M1892`, Snapdragon 845), currently using Linux 7.1-rc1.

The current public version is
[`2026.09-developer-preview.17`](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/tag/2026.09-developer-preview.17).
One 128-GB device has passed fresh installation, automatic growth, desktop,
5-GHz Wi-Fi, LTE data, Bluetooth, haptics, speaker, physical keys, automatic
rotation, emulation, Docker, cold boot and automated health checks.
Incoming/outgoing calls, SMS delivery, ringing, receiver, loudspeaker and
uplink microphone have also passed on one carrier/SIM. Independent
second-device and 64-GB hardware acceptance are still missing, so this is a
**developer preview**, not a stable release. See
[publication status](PUBLICATION_STATUS_EN.md) and
[known issues](KNOWN_ISSUES_EN.md) for the exact support boundary.

## Public assets

- Boot: `m1892-mainline-boot.img`, SHA-256
  `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526`.
- Firmware-free base: `m1892-mainline-base.raw.zst`, 1,808,945,214 bytes,
  SHA-256 `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad`.
- Decompressed raw: 8,589,934,592 bytes, SHA-256
  `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`.
- Kernel/DTB/audio-module bundle from the same clean build:
  `m1892-public-kernel.tar.gz`, 14,779,794 bytes, SHA-256
  `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c`.
- Open-source telephony UI dependencies: `m1892-telephony-apks.tar.gz`,
  5,677,559 bytes, SHA-256
  `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b`.
- Alpine radio runtime dependencies: `rmtfs-1.3-r0.apk` (13,759 bytes,
  SHA-256 `a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4`),
  `rmtfs-openrc-1.3-r0.apk` (2,162 bytes, SHA-256
  `5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769`), and
  `rmtfs-udev-1.3-r0.apk` (2,164 bytes, SHA-256
  `09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7`).
- M1892 call-audio/IMS/SMS runtime rebuilt from pinned source (including the
  SMS-over-IMS ModemManager patch):
  `m1892-telephony-audio-runtime.tar.gz`, 2,780,958 bytes, SHA-256
  `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf`.
- Corresponding call-runtime source: `m1892-telephony-audio-source.tar.gz`,
  6,885,734 bytes, SHA-256
  `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843`.
- Source archive: `m1892-mainline-source.tar.gz`; its `.sha256` sidecar in the
  same Release is authoritative.

The base is a **userdata build input and must not be flashed directly**. Each
owner must locally extract firmware from their own official Flyme 8.1.9.0A
package and build personal userdata. The repository and Release do not provide
Flyme firmware, firmware-complete userdata, a stock recovery tail, device logs,
ROMs, private keys or network credentials.

## Start here

- [Quick start (recommended)](QUICK_START_EN.md)
- [Detailed installation and rollback](INSTALL_EN.md)
- [Firmware extraction](FIRMWARE_EN.md)
- [Known issues](KNOWN_ISSUES_EN.md)
- [Build](BUILD_EN.md)
- [GitHub Actions and compile-free installation](ACTIONS_EN.md)
- [Publication status](PUBLICATION_STATUS_EN.md)
- [Licenses](LICENSES_EN.md)
- [Release notes](RELEASE_NOTES_EN.md)

## Docker quick acceptance

The desktop account can use Docker directly. This command builds a temporary
arm64 image from the phone's own BusyBox and musl, then tests networking, DNS,
volumes, resource limits, published ports, Compose and Buildx. No preloaded
container image is required, and all test resources are removed on exit:

```sh
m1892-docker-selftest
```

For an optional graphical manager, install the native aarch64 Flathub build of
Pods. Neither Pods nor Flatpak is preinstalled, avoiding roughly 2.4 GiB of
GNOME runtime data for users who do not need a graphical container manager.
Run this from a root administrative shell:

```sh
apk add flatpak
flatpak remote-add --system --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
flatpak install --system flathub com.github.marhkb.Pods
```

If Pods is installed after the current Phosh session started, its icon may not
appear in the application drawer immediately. Log out and back in (or reboot a
development image once) to refresh Flatpak's standard application export
directories. This is not an installation failure and does not require
reflashing boot or userdata.

## Safety summary

- Only for an unlocked device whose Fastboot product is exactly `M1892`.
- Installation erases Android `userdata` and writes `boot`.
- Never write GPT, modem/NV, calibration, `persist`, `proinfo` or `bootbak`.
- Verify this handset's stock boot/recovery and unique unbrick material first.
- Run explicit `flash-m1892.sh --check`; writes require full confirmation tokens.
- The desktop currently logs in automatically; `docker` membership grants
  effective root-equivalent host control.

This community research project is unaffiliated with Meizu, postmarketOS or
the Linux kernel project.
