# Meizu 16th Plus: Debian 13 + Plasma Mobile installation

[简体中文](PACKAGE_INSTALL.md) | English

Use this guide with the matching complete installation bundle attached to a
Release. GitHub's automatically generated “Source code” archive is not a flash
package. Do not use an unpublished, unvalidated candidate on a daily-use device.

## Requirements

- An unlocked Meizu **16th Plus**, Fastboot product **M1892**. Other Meizu models
  are unsupported. Bootloader unlocking is outside the installer.
- Windows 10/11, a reliable data cable, at least 5 GB free computer storage and
  adequate phone battery charge.
- Follow [backup and rollback preparation](BACKUP_EN.md) first; save your data and original boot/recovery, and retain any unique-device backups offline.
  **Installation erases all userdata: Android/Linux files, accounts, apps, games and saves.**
- Keep stock vendor, modem, Bluetooth, DSP data and the original Recovery tail compatible with
  Flyme 8.1.9.0A. The installer reads and verifies its required files before
  erasing userdata. It writes **boot, recovery and userdata**, preserving and
  validating this phone's stock Recovery tail. It does not write vendor, modem,
  Bluetooth, DSP, GPT, ABL, NV, persist, proinfo or calibration data.

No Linux compilation, WSL, Docker or manual Flyme extraction is required.
Firmware is imported offline from the phone being installed. The bundle does not
contain the developer's accounts, network profiles, keys or unique identity.

## Download and prepare

Download the full ZIP and matching `.sha256` from the same Release. Check it:

```powershell
Get-FileHash -Algorithm SHA256 .\m1892-debian13-plasma-mobile-install.zip
```

Compare with the sidecar, then extract the entire ZIP, for example to `C:\M1892`.
Do not run inside the ZIP viewer or combine files from different releases.
The directory contains `Install.ps1`, `Transport.psm1`, `install.cmd`,
`manifest.json`, the RAM environment, system image, Boot and Recovery template.

Download Windows Platform-Tools from [Google](https://developer.android.com/tools/releases/platform-tools).
Place its `platform-tools` directory beside `Install.ps1`, so
`platform-tools\fastboot.exe` exists. Windows must have a working Fastboot driver.

## Connect and install

Enter Fastboot with power and volume-down from power-off. Connect directly by
data cable and disconnect other phones. Run from the extracted directory:

```powershell
.\platform-tools\fastboot.exe devices
.\platform-tools\fastboot.exe getvar product
.\platform-tools\fastboot.exe getvar unlocked
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -VerifyOnly
```

Require one device, `product: M1892`, `unlocked: yes` and
`M1892_PACKAGE_VERIFY_PASS`. Resolve cable/port/driver problems first.

Double-click `install.cmd`. After backing up and reading the warning, type:

```text
ERASE-M1892-USERDATA
```

The installer enters its RAM environment, checks stock firmware, transfers,
writes and reads back userdata, expands to partition capacity, writes and reads
back Boot/Recovery, then requests reboot. USB disconnects/reconnects are expected.
Keep the cable attached; do not manually enter Recovery or launch another copy.
Transfers and filesystem checks can take several minutes.

`M1892_INSTALL_WRITE_READBACK_PASS` means writes and readback passed, not that
first-boot desktop acceptance is complete. A missing reboot acknowledgement does
not mean the system was not written; inspect the phone before retrying.

## First boot

Create your own username/password, reboot when prompted, then finish Plasma's
language, timezone, Wi-Fi, display and navigation setup. Simplified Chinese is
provided by default; English is selectable. There is no shared default password.
Check touch, rotation, sound and your required network functions.

Normal mode uses USB Host, so installation debug ports disappear. Expansion uses
actual userdata capacity; 128 GB has hardware evidence, other-capacity limitations
are stated in the Release. Restore your own apps, accounts, games and ROMs.

## Errors and recovery

- Stop on integrity or model errors; do not bypass checks.
- On incompatible firmware/Recovery, userdata is not erased, but Boot may already
  contain the temporary installer. Return to Fastboot and restore your saved Boot;
  resolve the stock partition compatibility before another installation.
- On transfer/readback/filesystem errors, keep the error output and do not write
  unrelated partitions. Restarting installation with the same complete bundle
  erases userdata again.
- If writes passed but reboot acknowledgement was lost, first wait and inspect
  the display, then reboot normally if needed. USB loss alone is not a reason to erase again.
- Restore an old system using its matching boot/recovery and system backup or the
  model's official recovery procedure. Restoring Boot cannot recover erased userdata.

Example for restoring your own matching Boot backup:

```powershell
.\platform-tools\fastboot.exe getvar product
.\platform-tools\fastboot.exe getvar unlocked
.\platform-tools\fastboot.exe flash boot .\original-boot.img
.\platform-tools\fastboot.exe reboot
```

Never directly flash `m1892-recovery-template.bin`: the installer combines it with
the phone's validated stock tail. Camera, deep low-power suspend and stock fast
charging remain subject to [limitations](KNOWN_ISSUES_EN.md).
