# Source and builds

[简体中文](BUILD.md) | English

This branch provides Debian integration and shared kernel source. **Source
contracts and individual components can be checked, but a complete flashable
Debian bundle cannot yet be rebuilt from a public clone alone.** Legacy local
Boot/Recovery inputs and runtime dependencies still need fully public acquisition
or build paths.

```sh
git clone --branch codex/debian13-plasma-mobile \
  https://github.com/NoobMaster233/meizu-m1892-mainline-linux.git
cd meizu-m1892-mainline-linux
python3 tools/verify-source.py .
sh tools/check-source.sh
```

These checks cover the source manifest, privacy patterns, configuration policy,
shell syntax, account states and partition geometry. They do not flash a phone
or establish fresh-image hardware acceptance.

- `src/debian/`: builders, systemd/desktop configuration, OEM setup, installer and patches.
- `src/public-release/`: shared kernel, device tree, boot and runtime components with their licenses.
- `SOURCE-MANIFEST.sha256`: hashes of this public source snapshot.
- `.github/workflows/source-contract.yml`: device-independent source checks.

Kernel components use `src/public-release/scripts/materialize-public-kernel.sh`
and `build-public-kernel.sh` with their input checks; the accepted toolchain is
AArch64 GCC 11.4. Debian rootfs builders use pinned snapshots, mmdebstrap and
native ARM64 or QEMU execution. Native Gamescope/MangoApp builders are under
`src/debian/scripts/`.

A complete image also requires sensor/media packages, Plasma Settings, IMS/audio
runtimes, matching modules, boot inputs and owner-local firmware. Some assemblers
still require legacy artifact hashes. No end-to-end image command sequence is
claimed yet. Do not remove checks, forge metadata or publish private inputs to
force a build through. Use a matching complete build/installation release when
one becomes available.
