# Backup and rollback preparation

[简体中文](BACKUP.md) | English

**Do not run the installer without a usable Boot rollback file and exported
personal data.** Boot is temporarily replaced before firmware preflight;
“userdata not erased” does not mean the previous system can immediately boot.
Boot/recovery backups do not back up photos, applications or saves.

## Android with existing root access

Export personal files, contacts and required app data to the computer first.
Raw partition reads below require working `su`; this is not a rooting/unlocking
guide. Connect only your M1892 and authorize your own computer for ADB. In
PowerShell in the Platform-Tools directory:

```powershell
.\adb.exe devices
.\adb.exe shell "su -c 'id'"
```

Continue only with one authorized `device`, successful `uid=0`, and confirmation
that it is your M1892. Stop on missing aliases, permission failures or errors;
never guess numeric partition names. Use a backup directory that does not exist:

```powershell
.\adb.exe shell "su -c 'test ! -e /sdcard/M1892-backup-before-linux && mkdir /sdcard/M1892-backup-before-linux'"
.\adb.exe shell "su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/M1892-backup-before-linux/original-boot.img bs=4M'"
.\adb.exe shell "su -c 'dd if=/dev/block/bootdevice/by-name/recovery of=/sdcard/M1892-backup-before-linux/original-recovery.img bs=4M'"
if (Test-Path .\M1892-backup-before-linux) { throw 'Choose a new computer backup directory' }
.\adb.exe pull /sdcard/M1892-backup-before-linux .\M1892-backup-before-linux
.\adb.exe shell "su -c 'sha256sum /sdcard/M1892-backup-before-linux/original-boot.img /sdcard/M1892-backup-before-linux/original-recovery.img'"
Get-FileHash -Algorithm SHA256 .\M1892-backup-before-linux\*.img
```

Every command must succeed. Each complete partition image must be 67,108,864
bytes; compare the computer SHA-256 hashes with the phone's output. Investigate any
size or hash mismatch. `su` interfaces
and authorization differ between Android setups; a failed command or empty file
is not a backup.

## An existing Linux installation

In the phone's ordinary-user terminal, use your own password for `sudo`:

```sh
mkdir "$HOME/M1892-backup-before-linux"
sudo dd if=/dev/disk/by-partlabel/boot of="$HOME/M1892-backup-before-linux/original-boot.img" bs=4M status=progress
sudo dd if=/dev/disk/by-partlabel/recovery of="$HOME/M1892-backup-before-linux/original-recovery.img" bs=4M status=progress
sudo chown -R "$(id -u):$(id -g)" "$HOME/M1892-backup-before-linux"
sha256sum "$HOME/M1892-backup-before-linux/"*.img
```

Copy the whole directory to the computer through your configured SSH/SFTP or
file-transfer route and compare the computer copies' SHA-256 hashes. Copies left
only on the phone will be erased with userdata.

## Fastboot only, without access to read the current system

This project does not claim that M1892's old Fastboot can read arbitrary
partitions. Obtain matching boot/recovery images or a reliable backup first.
The package's temporary installer Boot is not a backup of your old system.
Use the [official Flyme M1892 firmware page](https://www.flyme.com/firmwarelist-175.html)
as the entry point for stock recovery resources. Stock firmware cannot restore
unique identity or erased personal data. Keep custom Linux/ROM recovery files;
stock Boot is not a universal rollback for a custom system.

Keep any existing persist, modemst, fsg/fsc, private or proinfo backups offline.
They may contain identity/calibration state; do not upload them. This installer
does not write those partitions or offer generic EDL/Firehose recovery. Never
restore another device's raw backups onto yours.

See the [installation guide](PACKAGE_INSTALL_EN.md) for rollback and failure handling.
