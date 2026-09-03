# Known issues

[简体中文](KNOWN_ISSUES.md) | **English**

The following applies to the current developer preview:

- Automated regression evidence comes from one 128-GB device and does not mean
  every current artifact received a full rerun. There is no second-device or
  64-GB hardware acceptance.
- SMS send/receive, incoming/outgoing calls, ringing, receiver, loudspeaker,
  switching and uplink microphone have passed on one carrier/SIM. This path
  depends on carrier IMS/VoLTE and does not imply support on other networks.
  Call mute is not accepted yet, and speakerphone currently retains the
  handset-microphone route, so far-field pickup and echo control may be weaker
  than Flyme. Emergency calling is untested and the screen fingerprint reader
  is unsupported.
- The base locks passwords and contains no SSH key; the quick path requires an
  existing owner public key. There is no graphical account-creation wizard and
  the desktop logs in automatically. Its user belongs to `docker`, which grants
  effective root-equivalent host control; treat physical access as access to a
  developer device.
- Desktop boot is normally about one minute and may take longer during firmware retries.
- Full UFS runtime-PM level 3 causes hard hangs, so safe AH8 and explicit suspend are used.
- Shutdown with USB power attached may restart Linux; there is no charge-only off-mode UI.
- Charging is limited to the verified 5-V path; proprietary mCharge/24-W is disabled.
- Speaker playback works but is quieter than Flyme maximum.
- Phosh 0.56 has a narrow bottom-edge hit area for closing landscape quick settings.
- Stevia is verified for English input; Chinese input switching is not a release gate.
- Docker Engine, Compose and common network/storage paths are accepted with
  arm64 containers. This does not provide transparent x86-container emulation
  or turn the phone into a KVM-backed desktop VM platform.
- One 8-GiB sparse serves 64/128-GB models. Online growth is verified on 128-GB;
  64-GB has fail-closed boundary checks but no independent hardware evidence.
- Kernel and EDK2 sources and inputs are auditable. Actions performs semantic
  and ABI acceptance and records actual hashes, but different hosts may still
  produce different kernel, module, System.map or EDK2 bytes. The public base
  lacks a complete package-by-package rebuild path from an empty directory.

Treat [publication status](PUBLICATION_STATUS_EN.md) as the current support
contract. Do not infer support for anything not explicitly listed as passed.
