# Installation and recovery

[简体中文](INSTALL.md) | English

The [complete installation prerelease](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/tag/debian13-2026.10-preview.1)
is available, but it is not a stable release. Offline checks passed; a complete fresh
installation on hardware is still unverified. Keep your current system if you lack backups
and a recovery path. Source ZIPs are not flashing ZIPs, and a postmarketOS Release Boot
image is not a Debian installation input.

To test this prerelease, follow the [installation guide](PACKAGE_INSTALL_EN.md):
back up → download and verify → enter Fastboot → run the installer → create your account.
You do not need to enter the source directories or compile anything. Read the
[backup and rollback preparation](BACKUP_EN.md) before starting.

A full installation requires an unlocked M1892 and erases userdata. Bootloader
unlocking is outside this project. Keep offline copies of stock boot/recovery and
unique device data. GPT, ABL, modem/NV, persist, proinfo and calibration partitions
are outside the installation write scope.

The Windows installer source uses an independent RAM environment to validate the
device and assets, transfer userdata, read back its contents, check ext4, expand
to actual partition capacity and install matching Boot/Recovery. Use the complete ZIP
from one Release, not a mixture of assets. Do not replace that procedure with a generic
`fastboot flash userdata` command.

The bundle uses Calamares for account creation, followed
by Plasma's language, timezone, network and display setup. It will contain no
personal account or shared default password.

For an existing installation, use its matching recovery documentation and rollback
assets. Never mix Boot, Recovery, userdata or checksums from different releases.
