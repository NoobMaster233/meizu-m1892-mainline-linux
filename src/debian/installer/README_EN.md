# Meizu 16th Plus: precompiled local installation package

[简体中文](README.md)

> This template applies only to local bundles whose `manifest.json` has
> `scope: owner-local-complete`. For a `public-device-firmware` bundle, use the
> [public installation guide](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/blob/codex/debian13-plasma-mobile/PACKAGE_INSTALL_EN.md),
> not the local Recovery commands below. Both formats share installer source,
> but use different firmware sources and Recovery assets. This source directory
> does not contain flashable images.

**Owner-local complete package, not a redistributable public Release.** It includes model-level
firmware extracted from the owner's official Flyme archive, but no owner account, Wi-Fi profile,
SSH key, unique calibration or games. Do not upload or redistribute this ZIP until the applicable
firmware redistribution rights have been verified.
This local validation variant retains a USB root development console and disables automatic
deep suspend. Do not attach it to untrusted hosts. It is not a public daily-use release with
security and battery-life work completed.

## Install

Only for an unlocked **Meizu 16th Plus / M1892**, not the smaller 16th.
Installation erases all userdata, including Android/Linux files and game saves. Back up unique
device data not recoverable from an official archive and keep an offline recovery environment.

1. Extract all files on Windows. Obtain official [Google platform-tools](https://developer.android.com/tools/releases/platform-tools)
   and place the entire `platform-tools` directory next to `install.cmd`, or add fastboot to PATH.
2. Connect exactly one unlocked M1892 in Fastboot mode directly by USB.
3. Run `install.cmd`, then type `ERASE-M1892-USERDATA` when asked to confirm deletion.
4. Keep USB attached. The installer boots a RAM environment, streams and fully reads back userdata,
   checks and expands ext4 to the actual partition size, installs paired Boot/Recovery and reboots.
5. Complete account setup on the phone with your own username/password, then connect your Wi-Fi.

Plasma's official time/network/scaling/navigation wizard follows account creation; it is not a
second account setup. The system invokes Debian/KDE's original executable directly; the wizard,
desktop and other applications all use the default FD630 hardware acceleration. Description text
remnants may still occur during page transitions at some scales due to the known Qt Quick repaint issue.

No Linux build host, Docker, kernel compilation or manual firmware extraction is required.
Windows must support native USB NCM/ACM drivers and already have a working Fastboot driver.

## Recover

Keep the installation files. Do not erase other partitions. Userdata writing cannot start unless
RAM commissioning checks pass. After interruption, hold power + volume-down to enter Fastboot and
run the installer again; a retry also erases userdata.
If userdata was fully installed but the final Boot/Recovery step failed, run in Fastboot:

```powershell
.\platform-tools\fastboot.exe flash recovery .\m1892-system-recovery.img
.\platform-tools\fastboot.exe flash boot .\m1892-system-boot.img
.\platform-tools\fastboot.exe reboot
```

GPT, ABL, modem/NV, persist, proinfo and unique calibration are never modified.
The RAM installer Boot is not a daily-use Boot. Flashing it alone is not a complete installation.
Actual userdata geometry is used for 64/128 GB devices; the partition table is not changed.
The 128 GB device has been tested; 64 GB has offline geometry evidence only, not a physical test.
Camera and battery-life completion are not claimed. Account input, audible output and physical
peripherals after reinstallation still require real-use checks; installer success alone is not
acceptance of every daily-use feature.
