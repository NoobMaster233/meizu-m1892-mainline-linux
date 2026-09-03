# GitHub Actions and compile-free installation

[简体中文](ACTIONS.md) | **English**

GitHub Actions can validate public source and rebuild pinned public kernel,
EDK2 and telephony/IMS userspace components. It cannot safely create final owner userdata or flash a local
phone: required Flyme firmware is not redistributable, manual workflow inputs
are not a multi-GiB upload channel, and a cloud runner cannot access local USB
Fastboot hardware.

## Provided workflows

- `Public source contract` checks the public tree, privacy, licensing, script
  syntax, source manifest and deterministic archive on every push and PR.
- `Build public components` manually rebuilds `kernel`, `edk2`,
  `telephony-audio`, or `all`; the telephony job also emits corresponding
  source, and these short-lived artifacts are **not flashable images**.
- `Publish owner builder image` publishes a Flyme-free GHCR tool container and
  attaches its immutable digest to an existing draft Release.

Validation and component jobs have only `contents: read`; only the builder
publisher receives the write permissions needed for the package and draft
Release digest.

## Rebuild public components in your own fork

Ordinary users cannot dispatch manual workflows in the maintainer repository.
Fork this repository, open **Actions** in your fork, enable workflows, select
**Build public components**, then choose **Run workflow** and `kernel`, `edk2`,
`telephony-audio`, or `all`. A successful run exposes its build artifact on the run page for 7
days.

Those artifacts contain only verified kernel, EDK2 or telephony userspace
components rebuilt from pinned public source, plus corresponding telephony
source. They are for audit and development, are not complete userdata, and do
not replace the local owner-firmware step below.

## Compile-free owner userdata on a local computer

The host still needs a POSIX shell, Python 3, `sha256sum`, `timeout`, and
Android Platform Tools including `fastboot`. The container removes the Alpine
SDK and kernel-toolchain requirement; it does not access host USB. After
installing those basic flashing tools and Docker or Podman, create an empty working directory containing only
the official `Flyme-8.1.9.0A-update.zip` and an existing SSH public key named
`id_ed25519.pub`; `out` must not exist yet. The container supplies Alpine, apk,
e2fsprogs and extraction tools; no host kernel toolchain or Alpine SDK setup
is needed.

```sh
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fL "$release/m1892-owner-builder.digest" -o m1892-owner-builder.digest
image="$(cat m1892-owner-builder.digest)"
docker run --rm --privileged --platform linux/amd64 \
  -v "$PWD:/work" \
  "$image" \
  /work/Flyme-8.1.9.0A-update.zip /work/id_ed25519.pub /work/out
```

Podman uses the same digest. On an SELinux host, add `:Z` to the mount:

```sh
podman run --rm --privileged --platform linux/amd64 \
  -v "$PWD:/work:Z" "$image" \
  /work/Flyme-8.1.9.0A-update.zip /work/id_ed25519.pub /work/out
```

`--privileged` is used only to read-only mount the new ext4 image for the
second verification layer, but grants broad host authority. The Release
provides an immutable manifest digest; do not substitute a mutable tag.
The current tool image is published for `linux/amd64`; ARM64 hosts must enable
amd64 container emulation first. An incomplete temporary output is removed
automatically after a failed build, so the same command can be retried.
Otherwise follow
[Quick start](QUICK_START_EN.md) in local Alpine. The entrypoint coordinates
image mounts as root, but forcibly drops the `abuild` child step to a dedicated
regular user. The publication workflow tests both missing-input fail-closed
behavior and this privilege transition.

The container uploads nothing. Continue only after exit status 0 and all four
markers:

```text
M1892_LOCAL_FIRMWARE_IMAGE_PASS
M1892_LOCAL_FIRMWARE_VERIFY_PASS
M1892_FRESH_IMAGE_VERIFY_PASS
M1892_OWNER_BUNDLE_PASS
```

`out/` contains `m1892-userdata.sparse.img`, its required
`m1892-userdata.sparse.img.sha256` sidecar, and the verified
`out/tools/flash-m1892.sh` plus sibling `img2fullsimg.py`. No repository clone
or manual checksum step is needed.

Flash from the host by following [Installation](INSTALL_EN.md), using
`out/tools/flash-m1892.sh`: run `--check` first, then use the explicit erase
token. The container never accesses USB or bypasses product/unlock checks.

## Why Actions never receives Flyme

Public runners have limited temporary storage and `workflow_dispatch` accepts
small structured inputs, not file uploads. Putting Flyme credentials in inputs
or logs, or uploading firmware-complete userdata as an artifact, creates
privacy, copyright, retention and supply-chain risk. The cloud handles only
public source/components; the local container handles private owner inputs.
