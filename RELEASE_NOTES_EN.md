# 2026.09-developer-preview.17 release notes

[简体中文](RELEASE_NOTES.md) | **English**

This is the current developer preview for external testers. Use images,
sources and checksum files from the same GitHub Release only.

## Public asset contract

| Asset | Bytes | SHA-256 |
|---|---:|---|
| `m1892-mainline-boot.img` | 67108864 | `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526` |
| `m1892-mainline-base.raw.zst` | 1808945214 | `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad` |
| Decompressed `m1892-mainline-base.raw` | 8589934592 | `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46` |
| `m1892-public-kernel.tar.gz` | 14779794 | `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c` |
| `m1892-telephony-apks.tar.gz` | 5677559 | `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b` |
| `rmtfs-1.3-r0.apk` | 13759 | `a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4` |
| `rmtfs-openrc-1.3-r0.apk` | 2162 | `5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769` |
| `rmtfs-udev-1.3-r0.apk` | 2164 | `09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7` |
| `m1892-telephony-audio-runtime.tar.gz` | 2780958 | `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf` |
| `m1892-telephony-audio-source.tar.gz` | 6885734 | `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843` |

Call this version published only when every downloadable asset in the table,
the source archive, and every sidecar required by the documentation appear
together in one GitHub Release. The base raw is a
firmware-free userdata build input and must not be flashed directly.
The Release must also include `m1892-owner-builder.digest`, which pins the
quick-start container to an immutable GHCR manifest rather than a mutable tag.

## What this version includes

- A fresh userdata can be rebuilt, strongly verified and flashed from the public
  base plus the owner's own Flyme package.
- Fresh installs explicitly restore a device-unique Bluetooth address. The
  pure-Python modules used by call/IMS are bundled, so call-audio services need no
  package download on the target device.
- ModemManager is rebuilt from a pinned upstream commit and first sets the QMI
  WMS `SMS on IMS` hint on LTE/IMS networks. It retries once through the default
  domain when the modem explicitly rejects IMS, retaining CS-SMS compatibility.
- USB connections to a PC accept the observed safe 475 mA current limit instead
  of falsely failing the power-policy check.
- The owner-image build writes and byte-verifies the current public power
  and health-check implementations instead of inheriting stale base copies.
- The recommended owner-image tool now emits and verifies the standalone sparse
  checksum required by the flashing helper; the base verifier also distinguishes
  base content from files written while generating the owner image.
- One installer image supports both 64-GB and 128-GB models and grows on first boot.
- Desktop, 5-GHz Wi-Fi, LTE data, Bluetooth, speaker, automatic rotation,
  emulation and Docker.
- SMS, incoming/outgoing calls, ringtone, receiver/speaker switching and
  bidirectional call audio.
- The quick path requires an existing owner SSH public key; password login stays locked.
- GitHub Actions validates public source and can rebuild the public kernel,
  EDK2 and call-audio components; a Flyme-free local builder container avoids
  host compilation.
- Preflight enforces product/unlock state, an 8-GiB all-RAW sparse, Boot and digests.
- Vendor firmware and sensor calibration remain local to the owner's official
  package/device and never enter the Release.

## Owner-local artifacts

Each firmware-complete raw and sparse image is local to its owner's device.
It contains copyrighted firmware extracted from that owner's official Flyme
package, is not a public Release asset, and must never be uploaded or redistributed.

## Acceptance and reproducibility boundary

One 128-GB M1892 passed complete flashing, first growth, desktop, 5-GHz Wi-Fi,
LTE IPv4/IPv6, Bluetooth, haptics, speaker, physical keys, automatic rotation,
emulation, Docker, SMS, incoming/outgoing calls, ringtone, receiver/speaker
switching, bidirectional call audio, cold boot and automated health checks. Docker coverage
includes the default bridge, user-defined-network DNS, volumes, bind mounts,
memory limits, published ports, Compose and regular-user access. Independent
second-device and 64-GB hardware acceptance are still missing, so this is not stable.

Kernel and EDK2 source, commits, configuration and inputs are publicly
auditable. Actions strictly checks kernel release, module ABI, configuration,
symbols, device-tree semantics and the canonical DTB hash, and records each
run's actual binary hashes. Compiler/binutils packaging and generated metadata
mean kernel, module, System.map and EDK2 bytes are not promised identical across
hosts. The public base still lacks a complete package-by-package rebuild path
from an empty directory. Auditable inputs are not byte-for-byte rebuildability
of every artifact.

Start with the [quick start](QUICK_START_EN.md), then read
[known issues](KNOWN_ISSUES_EN.md) and [publication status](PUBLICATION_STATUS_EN.md).
