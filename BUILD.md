# 构建说明

**简体中文** | [English](BUILD_EN.md)

本文面向需要审计或重建公开产物的开发者。只想安装的机主应从
[懒人安装手册](QUICK_START.md)开始。

## 输入与输出

公开构建使用固定的内核源码/补丁/配置、设备树、公开 initramfs、EDK2
源码和 postmarketOS 软件包集合。完整硬件支持所需的 Flyme 固件必须由机主
自己提供并在本地校验；私有验收镜像不是公开构建输入。

本地产物目录应包含：

```text
m1892-mainline-boot.img
m1892-mainline-boot.img.sha256
m1892-public-kernel.tar.gz
m1892-public-kernel.tar.gz.sha256
m1892-userdata.sparse.img
m1892-userdata.sparse.img.sha256
```

boot 是带 AVB `NONE` hash footer 的 64 MiB 镜像。userdata 是 Android sparse，
内部为 8 GiB ext4，label `pmOS_root`，UUID
`3982b874-0ec0-57c4-a83b-37965b6be709`。

## 源码归档

```sh
./scripts/verify-public-tree.sh .
./scripts/make-public-source-archive.sh \
  . ../m1892-mainline-source.tar.gz
```

归档器会复查 allow-list、隐私、私有 payload、许可证和源码清单，并使用排序
路径、固定时间戳、数字 root 所有权和 `gzip -n` 生成确定性归档。最终
SHA-256 在归档生成后写入同名 `.sha256` sidecar；归档内部不嵌入自身哈希。
输出必须位于源码树之外，避免把正在生成的归档重新收进自身。

## 公开基础镜像与支持的重建范围

```text
asset               m1892-mainline-base.raw.zst
compressed bytes    1808945214
compressed sha256   fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad
raw bytes           8589934592
raw sha256          dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46
```

该 raw 不含厂商固件、机器身份、SSH key 或机主网络凭据；只带不含 APN、
用户名和密码的运营商中立蜂窝自动配置。它只是 userdata 构建输入，不能直接
刷写。finalizer 要求 e2fsprogs 1.47.4 或更新版本，且 `zerofree` 必须
链接同一版本库。

当前完整支持并由快速手册验收的是：从这个固定、公开、无厂商固件的 base，
结合机主自己的 Flyme 包，重建并验证一份全新的可刷 userdata。公开仓库尚未
承诺从空目录逐包重建出字节完全相同的 base；该限制不应与“机主安装包可从
公开输入重建”混为一谈。

## 账户与本地固件

完整源码构建应在 `pmbootstrap install` 前选择账户：

```sh
cp config/build-options.env.example out/build-options.env
. out/build-options.env
pmbootstrap config user "$M1892_BUILD_USER"
pmbootstrap config hostname "$M1892_BUILD_HOSTNAME"
pmbootstrap install
```

密码登录保持锁定。用于实际安装的快速路径必须注入机主已有公钥：

```sh
test -s "$HOME/.ssh/id_ed25519.pub"
export M1892_ROOT_AUTHORIZED_KEYS_FILE="$HOME/.ssh/id_ed25519.pub"
```

固件提取和注入步骤见 [厂商固件说明](FIRMWARE.md)。仅在**不注入公钥**的基准
生成中，机主本地固件完整 raw SHA-256 为
`596b37a306397be06538705db979beed0747bf939745104fa0f452ac7bcc488f`，
sparse SHA-256 为
`cc6025bed15d0c6043f657d0b2b8683cc54591cf31bd692f1239c151af426aab`。
注入任意公钥都会按预期改变这两个哈希；应以本次生成的 sidecar 和强校验器为
准。含机主固件的产物不得上传或再分发。

## 构建 boot

准备固定提交的 `sdm845-mainline/linux` 克隆。EDK2 必须递归初始化子模块。
先按前文的机主镜像流程生成 `out/m1892-userdata.raw`；boot 组合器会从中读取
经过校验的 BusyBox 和 musl。以下 Debian/Ubuntu 依赖覆盖内核、EDK2 和 boot
组合器：

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

内核构建器要求 GCC 11.4.0/Binutils 2.38，并固定提交时间戳和 Kbuild 身份。
`make-public-boot-image.sh` 是发布参考 boot 的严格组合器，只接受与公开清单
逐字节一致的内核/DTB；若宿主工具链生成不同字节，它会安全拒绝，不能用跳过
哈希来“修复”。此时应直接使用 Release 的已校验 boot。Actions 可以独立重建
内核和 EDK2 组件用于审计，但目前不会在云端组合最终 boot。
校验器检查两层 Android boot、AVB、各组件、命令行和 initramfs 条目集合。
EDK2 构建器会核对固定提交、子模块、补丁与配置并生成清单；boot 校验器随后
把 loader 和该清单一起纳入验证。
内核工作流同时打包与该 boot 完全同源、同 ABI 的 CS35L41/SDM845 扬声器
模块；机主 userdata 构建器校验清单后写入这些模块，不再沿用历史预编译副本。

## 构建通话/IMS 运行包

公开脚本从固定提交重建 callaudiod、q6voiced、81voltd、qcom-imsd 和
ModemManager。随附的 ModemManager 补丁会为 3GPP QMI 短信优先设置标准
`SMS on IMS` 提示，使 LTE/IMS 网络不再错误尝试已分离的 CS 域；若基带明确
返回 IMS 域不可用，则只回退一次默认域，从而保留 CS 网络兼容性。输出中不含
Flyme 私有库：

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

该构建需要 aarch64 Alpine 环境；在其他架构上可通过 GitHub Actions 的
`telephony-audio` 组件任务重建。Release 中的包及 sidecar 是快速安装路径的
固定输入；对应源码包提供上游快照、项目补丁、依赖 wheel 和许可证，供离线
审计与许可证合规使用。

## Recovery-first 测试

不要把 64 MiB boot 容器直接写入 `recovery`，否则会覆盖 ABL 需要的原厂
recovery AVB tail。只能用本机经哈希核验的原厂 recovery 在本地生成 hybrid。
当前唯一支持的输入是 M1892 Flyme 8.1.9.0A 的 64 MiB 原厂 recovery，
SHA-256 必须为
`faffac470b6eb984167b48c303177efd9fb20be2b2d5f0402d06a3a49605a997`；
其他版本会被脚本拒绝，不要绕过检查：

```sh
./scripts/make-public-recovery-image.sh \
  out/m1892-mainline-boot.img inputs/owner-stock-recovery.img \
  out/m1892-mainline-recovery-test.img
./scripts/verify-public-recovery-image.sh \
  out/m1892-mainline-recovery-test.img out/m1892-mainline-boot.img \
  inputs/owner-stock-recovery.img
```

hybrid 只用于有人值守测试，绝不上传。只有 recovery-first 通过后才可更换日用
`boot`。强制重启后重试未改动的 boot 前，应在 RAM rescue 中确认
`/dev/sda19` 未挂载，再运行 `e2fsck -fn`。

## 可复现性边界

内核、DTB、initramfs 策略、AVB 布局和根 UUID 有公开构建与独立验证路径。
内核和 EDK2 的源码、提交、配置和输入清单可以审计；工作流会严格验证内核
release、模块 ABI、配置、符号和设备树语义，并固定规范化后的 DTB 哈希。
不过不同发行版打包的编译器/binutils、绝对构建路径和生成元数据仍可能使
内核、模块、System.map 或 EDK2 跨宿主输出字节不同，所以工作流记录每次实际
哈希，而不拿另一台宿主的二进制哈希冒充功能验收。公开 base 仍没有从空目录
逐包重建的完整路径；输入可审计不等于所有产物均可逐字节重建。
