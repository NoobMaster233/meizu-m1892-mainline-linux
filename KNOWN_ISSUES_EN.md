# Features and limitations

[简体中文](KNOWN_ISSUES.md) | English

This is the live-device test scope, not acceptance of a current complete bundle.

| Feature | Evidence and limitations |
|---|---|
| Desktop, display, touch | Plasma Mobile, FD630 hardware rendering, touch, brightness and blank/wake have device evidence. Some desktop applications do not fit narrow screens. |
| Sensors | Accelerometer, rotation, light and proximity have test evidence. Rotation behavior can vary by application. |
| Networking | 2.4/5 GHz Wi-Fi and LTE data tested. Each device reads its own factory WLAN identity; no shared owner MAC is shipped. |
| Calls and SMS | SMS, incoming/outgoing calls and receiver/speaker/microphone tested with one carrier/SIM. Other carriers and emergency calls are unverified. |
| Bluetooth | HID pairing/reconnection tested. This does not establish support for every headset or peripheral. |
| Audio and video | Speaker, recording and call routes tested. Venus H.264 decoding is limited to integrated application paths, not every browser or codec. |
| USB and charging | Host gamepad and bounded charge-through tested. Conservative 5 V charging; no stock 24 W fast-charge claim. |
| Docker and gaming | Docker, RetroArch and Gamescope have test evidence. Steam/translation compatibility and performance vary; no games or accounts are included. |
| Storage | Installation/expansion tested on 128 GB hardware. 64 GB has logic tests only. Unexpected power loss has caused ext4 damage; keep backups. |
| Suspend | Manual and automatic suspend are disabled by default. Long suspend/resume remains unreliable. Screen-off keeps the system running; phone-level battery life is not achieved. |
| Camera, fingerprint, NFC | No usable camera release; fingerprint and NFC are unsupported. |
| Overclocking | Public GPU default is 710 MHz. CPU uses hardware-defined states. Device-specific tuning is not a stability guarantee for other units. |

Initial setup and some settings pages may have upstream layout limitations.
Encrypted KWallet may require unlocking once per session with automatic login.
Plaintext login passwords are not saved to bypass this.
