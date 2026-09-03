# Publication status

[简体中文](PUBLICATION_STATUS.md) | **English**

Version: `2026.09-developer-preview.17` (developer preview, not stable)

## Published and verified

- Boot: `m1892-mainline-boot.img`, SHA-256
  `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526`.
- Base: `m1892-mainline-base.raw.zst`, 1,808,945,214 bytes, SHA-256
  `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad`.
- Decompressed raw: 8,589,934,592 bytes, SHA-256
  `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`.
- Kernel/DTB/audio-module bundle: `m1892-public-kernel.tar.gz`, SHA-256
  `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c`.
- Telephony UI dependency archive: `m1892-telephony-apks.tar.gz`, SHA-256
  `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b`.
- Pinned Alpine `rmtfs`, `rmtfs-openrc`, and `rmtfs-udev` APKs; sizes and
  SHA-256 values are listed in the [README](README_EN.md) and enforced by the
  download script.
- Pinned-source call-audio/IMS runtime: `m1892-telephony-audio-runtime.tar.gz`
  and its `.sha256` sidecar, SHA-256
  `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf`.
- Corresponding call-runtime source: `m1892-telephony-audio-source.tar.gz`,
  6,885,734 bytes, SHA-256
  `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843`.
- Source archive `m1892-mainline-source.tar.gz` and asset sidecars. The
  archive's `.sha256` sidecar in the same Release is authoritative.
- `m1892-owner-builder.digest`, containing the immutable GHCR manifest digest
  for the compile-free owner tool image; users must not substitute a mutable tag.
- One 128-GB device has passed fresh installation, automatic growth, desktop,
  5-GHz Wi-Fi, LTE data, Bluetooth, haptics, speaker, physical keys, automatic
  rotation, emulation, Docker, cold boot and automated health checks.
  SMS, incoming/outgoing calls and bidirectional call audio also passed on one
  carrier/SIM.
- Docker 29.7.2 has passed default-bridge DNS/egress, user-defined-network DNS,
  named volumes, bind mounts, memory limits, published ports, Compose and
  access from the regular desktop account.
- The public source passed privacy, proprietary-file, license, link and source-manifest checks.

The base contains no vendor firmware, owner key or network credential and must
not be flashed directly. Firmware-complete userdata and recovery with a stock
tail are not public assets.

The path from the pinned public base, the owner's own Flyme package and Release
runtime packages to a flashable userdata is public and independently
verifiable. That is distinct from rebuilding a byte-identical base
package-by-package from an empty directory, which remains incomplete below.

## Not yet complete

- Independent second-device/user acceptance and 64-GB hardware acceptance.
- A complete attended retest of every hardware feature for this version.
- IMS/VoLTE and SMS compatibility on other carriers/SIMs, call mute,
  emergency calling and the screen fingerprint reader.
- Cross-host byte determinism for kernel, modules, System.map and EDK2
  (functional and ABI acceptance is covered by Actions).
- A complete package-by-package rebuild path for the public base from an empty
  directory.

See [known issues](KNOWN_ISSUES_EN.md) for user-facing limits and the
[release notes](RELEASE_NOTES_EN.md) for current asset and
acceptance boundaries. Do not label stable before independent-device acceptance.
