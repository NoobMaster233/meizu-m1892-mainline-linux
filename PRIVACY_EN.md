# Privacy and firmware

[简体中文](PRIVACY.md) | English

Public source is exported from an allowlist without the private development
repository or its history. Checks scan common patterns for personal network
addresses, account paths, SSH keys, password hashes, access tokens and network
secrets, and reject logs and build outputs. They cannot identify every possible
secret format; independent content review is also required. Public CI runs
device-independent source checks only.

Images must be built afresh, not cloned from a used phone. The final filesystem
also needs checks for accounts, SSH host/authorized keys, machine-id, network
profiles, Bluetooth pairing, wallets, browser sessions, logs and deleted-file
residue. Source scanning does not substitute for image scanning.

Some hardware requires vendor firmware. Current complete local images use files
extracted from an owner's Flyme package; they are not provided as public assets
on this branch. Vendor files without redistribution permission and unique device
data must not be uploaded. A future vendor-free base will need local firmware
import; this installation entry point is not complete and is not yet a one-click
installation path.

Owners create their account on first boot; hardware identity is read per device.
Development USB access is separate from normal Host mode. Public defaults must
never include the developer's remote authorization.
