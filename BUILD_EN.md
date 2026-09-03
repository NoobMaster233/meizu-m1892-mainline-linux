# Build

[简体中文](BUILD.md) | **English**

This document is for developers auditing or rebuilding public artifacts. Device
owners who only want to install should start with the [quick start](QUICK_START_EN.md).

## Inputs and outputs

Public builds use pinned kernel source/patches/configuration, device trees,
public initramfs, EDK2 source and postmarketOS packages. Flyme firmware needed
for full hardware support must be owner-supplied and locally verified. Private
acceptance images are not public build inputs.

The local output directory should contain:

```text
m1892-mainline-boot.img
m1892-mainline-boot.img.sha256
m1892-public-kernel.tar.gz
m1892-public-kernel.tar.gz.sha256
m1892-userdata.sparse.img
m1892-userdata.sparse.img.sha256
```

Boot is a 64-MiB image with an AVB `NONE` hash footer. Userdata is Android
sparse carrying an 8-GiB ext4 filesystem with label `pmOS_root` and UUID
`3982b874-0ec0-57c4-a83b-37965b6be709`.

## Source archive

```sh
./scripts/verify-public-tree.sh .
./scripts/make-public-source-archive.sh \
  . ../m1892-mainline-source.tar.gz
```

The archiver rechecks the allow-list, privacy, proprietary payload, license and
source manifest gates. Sorted paths, fixed timestamps, numeric root ownership
and `gzip -n` make the archive deterministic. The final SHA-256 is written to
the archive's `.sha256` sidecar after generation; the archive does not embed
its own digest.
The output must stay outside the source tree so the archive cannot include the
file that is currently being generated.

## Public base and supported rebuild scope

```text
asset               m1892-mainline-base.raw.zst
compressed bytes    1808945214
compressed sha256   fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad
raw bytes           8589934592
raw sha256          dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46
```

The raw contains no vendor firmware, machine identity, SSH key or owner network
credential. It carries only a carrier-neutral cellular autoconnect profile with
no APN, username or password. It is a userdata build input and must not be flashed directly. The
finalizer requires e2fsprogs 1.47.4 or newer, with `zerofree` linked to the
same library.

The fully supported quick-start build is a fresh, verified, flashable owner
userdata built from this pinned public firmware-free base plus the owner's own
Flyme package. The public repository does not yet promise a byte-identical base
rebuilt package-by-package from an empty directory. Do not confuse that limit
with the reproducibility of the owner install package from public inputs.

## Accounts and local firmware

Select an account before `pmbootstrap install` for a full source build:

```sh
cp config/build-options.env.example out/build-options.env
. out/build-options.env
pmbootstrap config user "$M1892_BUILD_USER"
pmbootstrap config hostname "$M1892_BUILD_HOSTNAME"
pmbootstrap install
```

Keep password login locked. A fast-path image intended for installation must
inject an existing owner public key:

```sh
test -s "$HOME/.ssh/id_ed25519.pub"
export M1892_ROOT_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub"
```

See [Firmware](FIRMWARE_EN.md) for extraction and injection. Only the
**key-free baseline build** has owner-local firmware-complete raw SHA-256
`596b37a306397be06538705db979beed0747bf939745104fa0f452ac7bcc488f`;
its sparse SHA-256 is
`cc6025bed15d0c6043f657d0b2b8683cc54591cf31bd692f1239c151af426aab`.
Injecting any public key intentionally changes both hashes; use the generated
sidecar and strong verifier for that build. Never upload or redistribute an
owner-firmware-complete image.

## Build boot

Prepare the pinned `sdm845-mainline/linux` commit and initialize EDK2
submodules recursively. First complete the owner-image procedure above so
`out/m1892-userdata.raw` exists; the boot composer extracts verified BusyBox
and musl from it. These Debian/Ubuntu dependencies cover the kernel, EDK2 and
boot composer:

```sh
sudo apt-get update
sudo apt-get install -y acpica-tools bc binutils-aarch64-linux-gnu bison \
  build-essential clang cpio device-tree-compiler e2fsprogs flex gcc-aarch64-linux-gnu \
  gcc-11-aarch64-linux-gnu gettext git kmod libelf-dev libssl-dev llvm \
  make mkbootimg nasm python3 uuid-dev
mkdir -p out/tools
curl -fsSL \
  'https://android.googlesource.com/platform/external/avb/+/refs/tags/android-14.0.0_r1/avbtool.py?format=TEXT' \
  | base64 -d >out/tools/avbtool
printf '%s  %s\n' \
  1f1fddd2764eba76dc659415406062251edcf2eb6b4e83b0f01d0224cd631281 \
  out/tools/avbtool | sha256sum -c -
chmod 0755 out/tools/avbtool
export PATH="$PWD/out/tools:$PATH"
git clone https://gitlab.com/sdm845-mainline/linux.git out/linux-upstream
git -C out/linux-upstream checkout 85f1df2a4ec71d7a91dd95a7a49f889d1595ffa8
git clone https://github.com/edk2-porting/edk2-sdm845.git out/edk2-sdm845
git -C out/edk2-sdm845 checkout e1952621f419f8db60ed28271264e1b5184c571d
git -C out/edk2-sdm845 submodule update --init --recursive
./scripts/materialize-public-kernel.sh out/linux-upstream out/linux-m1892
./scripts/build-public-kernel.sh out/linux-m1892 out/kernel
./scripts/verify-public-kernel.sh out/kernel
./scripts/package-public-kernel.sh \
  out/kernel out/m1892-public-kernel.tar.gz
./scripts/build-public-edk2-loader.sh out/edk2-sdm845 out/edk2
./scripts/make-public-boot-image.sh \
  out/kernel/arch/arm64/boot/Image.gz \
  out/kernel/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb \
  out/edk2/workspace/uefi-m1892-kernel \
  out/edk2/M1892-EDK2-BUILD-MANIFEST.txt \
  out/m1892-userdata.raw \
  out/m1892-mainline-boot.img
./scripts/verify-public-boot-image.sh \
  out/m1892-mainline-boot.img \
  out/kernel/arch/arm64/boot/Image.gz \
  out/kernel/arch/arm64/boot/dts/qcom/sdm845-meizu-m1892-current-product.dtb \
  out/edk2/workspace/uefi-m1892-kernel \
  out/edk2/M1892-EDK2-BUILD-MANIFEST.txt
```

The kernel builder requires GCC 11.4.0/Binutils 2.38 and pins the commit time
and Kbuild identity. `make-public-boot-image.sh` is the strict reference-boot
composer and accepts only kernel/DTB bytes matching the public manifest. A
different toolchain must fail closed; do not bypass the hashes. Use the verified
Release boot instead. Actions can independently rebuild the kernel and EDK2
components for audit, but currently does not compose the final boot in the cloud.
The verifier checks both Android boot layers, AVB,
components, command line and the initramfs entry set.
The EDK2 builder checks the pinned commits, submodules, patches and
configuration and emits a manifest; the boot verifier then validates the
loader together with that manifest.
The kernel workflow also packages CS35L41/SDM845 speaker modules from the same source and ABI as the
boot; the owner-local userdata builder verifies and installs those modules
instead of reusing historical prebuilt copies.

## Build the telephony/IMS runtime

The public script rebuilds callaudiod, q6voiced, 81voltd, qcom-imsd, and
ModemManager from pinned commits. The included ModemManager patch first sets
the standard `SMS on IMS` hint for 3GPP QMI SMS requests, avoiding an incorrect
attempt to use a detached circuit-switched domain on LTE/IMS networks. If the
modem explicitly reports that IMS is unavailable, it retries once through the
default domain to retain compatibility with circuit-switched SMS. The
output contains no proprietary Flyme library:

```sh
./scripts/build-m1892-telephony-audio-runtime.sh \
  out/m1892-telephony-audio-runtime.tar.gz \
  out/m1892-telephony-audio-source.tar.gz
sha256sum -c out/m1892-telephony-audio-runtime.tar.gz.sha256
sha256sum -c out/m1892-telephony-audio-source.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  out/m1892-telephony-audio-runtime.tar.gz
./scripts/verify-m1892-telephony-audio-source.sh \
  out/m1892-telephony-audio-source.tar.gz
```

This build requires an aarch64 Alpine environment. On other architectures,
use the `telephony-audio` GitHub Actions component job. The archive and
sidecar in the Release are the pinned inputs for the quick installation path.
The corresponding-source archive carries upstream snapshots, project patches,
dependency wheels and licenses for offline audit and license compliance.

## Recovery-first testing

Do not write the 64-MiB boot container directly to `recovery`; that would
overwrite the stock recovery AVB tail required by ABL. Build a local hybrid
only from this handset's hash-verified stock recovery. The only supported input
is the 64-MiB stock recovery from M1892 Flyme 8.1.9.0A. Its SHA-256 must be
`faffac470b6eb984167b48c303177efd9fb20be2b2d5f0402d06a3a49605a997`.
The scripts reject other versions; do not bypass that check:

```sh
./scripts/make-public-recovery-image.sh \
  out/m1892-mainline-boot.img inputs/owner-stock-recovery.img \
  out/m1892-mainline-recovery-test.img
./scripts/verify-public-recovery-image.sh \
  out/m1892-mainline-recovery-test.img out/m1892-mainline-boot.img \
  inputs/owner-stock-recovery.img
```

The hybrid is for attended testing only and must never be uploaded. Replace
daily `boot` only after recovery-first acceptance. Before retrying unchanged
boot after forced resets, use RAM rescue, require `/dev/sda19` to be unmounted,
and run `e2fsck -fn`.

## Reproducibility boundary

The kernel, DTB, initramfs policy, AVB layout and root UUID have public build
and independent verification paths. Kernel and EDK2 source, commits,
configuration and inputs are auditable. The workflow strictly checks kernel
release, module ABI, configuration, symbols and device-tree semantics, and pins
the canonical DTB hash. Distribution-packaged compiler/binutils, absolute paths
and generated metadata can still change kernel, module, System.map or EDK2 bytes
across hosts, so each run records its actual hashes instead of treating another
host's binary hashes as a functional test. The public base still lacks a full
package-by-package rebuild path from an empty directory. Auditable inputs do not
mean every artifact is byte-rebuildable.
