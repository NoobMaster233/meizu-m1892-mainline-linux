# 私有厂商固件边界

**简体中文** | [English](FIRMWARE_EN.md)

本文中的 `sudo` 代表机主已配置的提权工具；最小 Alpine 若未安装 `sudo`，可在
需要挂载或写 loop 设备的步骤使用 `su -` root shell。固件提取和 `abuild`
本身仍必须以普通用户运行。

M1892 的 GPU、视频、蜂窝、Wi-Fi、蓝牙和传感器路径需要设备签名的厂商固件。
这些文件受版权保护，本项目只公开文件清单/哈希、提取与本地注入源码、软件包
配方，以及开源内核和用户态修改。

仓库和 Release **不提供** Flyme 包或其成员、原厂 boot/recovery tail、含厂商
固件的 rootfs/initramfs，或从开发手机复制的固件。每位机主必须使用自己下载的
Flyme 8.1.9.0A 官方包；生成物只能本地使用，不能提交或再分发。

## 下载与提取

克隆 `qca-swiss-army-knife` 提交
`34fa4d6bd6641c79e6a6384816314fbbcd5a23cc`，然后运行：

```sh
./scripts/download-official-flyme.sh --check
./scripts/download-official-flyme.sh --download out/Flyme-8.1.9.0A-update.zip
export ATH10K_BDENCODER=/path/to/qca-swiss-army-knife/tools/scripts/ath10k/ath10k-bdencoder
./scripts/extract-flyme-firmware.sh out/Flyme-8.1.9.0A-update.zip \
  out/local-firmware out/m1892-firmware-runtime-20260831.tar.gz
```

提取器无挂载地读取官方镜像，校验所有预期成员，并生成 146 文件清单和确定性
本地归档。归档必须精确匹配：

```text
bytes   50161209
sha256  381d1873fcbac5d39e16ecd97fe2ccad214465748614cbccc49d21b6727e9133
sha512  474dbb8e25e8e38f9e1880b5310e830c51a71732bdcf0264b31b1bac092173ab5eea3f2ad599900e2bef1d5f73a04c456c36521edfdce5fd5c2cca670f0dd3dd
```

在安装了 `alpine-sdk` 的 Alpine 环境中，以普通用户构建 APK：

```sh
./scripts/build-local-firmware-apk.sh \
  out/m1892-firmware-runtime-20260831.tar.gz \
  out/firmware-meizu-m1892-20260831-r0.apk
./scripts/download-runtime-apks.sh out/alpine-rmtfs-1.3-r0-aarch64
```

APK 外层签名和元数据可能因本地密钥而不同，因此生成脚本和校验脚本检查软件包
身份及每个安装文件，而不是要求整包哈希一致。两个开放 A630 固件来自固定
的 linux-firmware `20260221` 标签，并由配方校验，不从 Flyme 复制。

## 生成本地 userdata

先校验并解压公开基础镜像：

```sh
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
sudo env M1892_FIRMWARE_MODE=absent \
  ./scripts/verify-fresh-image.sh out/m1892-mainline-base.raw
```

再注入机主固件与固定的 Alpine `rmtfs` 软件包：

```sh
RELEASE=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fLO "$RELEASE/m1892-telephony-audio-runtime.tar.gz"
curl -fLO "$RELEASE/m1892-telephony-audio-runtime.tar.gz.sha256"
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
OWNER_PUBLIC_KEY="$HOME/.ssh/id_ed25519.pub" # 可替换为已有的 RSA/ECDSA/FIDO 公钥
test -s "$OWNER_PUBLIC_KEY"
export M1892_ROOT_AUTHORIZED_KEYS_FILE="$OWNER_PUBLIC_KEY"
export M1892_TELEPHONY_AUDIO_ARCHIVE="$PWD/m1892-telephony-audio-runtime.tar.gz"
./scripts/make-local-firmware-image.sh \
  out/m1892-mainline-base.raw \
  out/firmware-meizu-m1892-20260831-r0.apk \
  out/alpine-rmtfs-1.3-r0-aarch64 \
  m1892-public-kernel.tar.gz \
  out/m1892-userdata.raw
./scripts/verify-local-firmware-image.sh \
  out/m1892-userdata.raw \
  out/firmware-meizu-m1892-20260831-r0.apk \
  out/alpine-rmtfs-1.3-r0-aarch64 \
  m1892-public-kernel.tar.gz
sudo env M1892_FIRMWARE_MODE=complete \
  M1892_EXPECT_ROOT_AUTHORIZED_KEYS_FILE="$M1892_ROOT_AUTHORIZED_KEYS_FILE" \
  ./scripts/verify-fresh-image.sh out/m1892-userdata.raw
./scripts/img2fullsimg.py \
  out/m1892-userdata.raw out/m1892-userdata.sparse.img
./scripts/img2fullsimg.py --verify-against \
  out/m1892-userdata.sparse.img out/m1892-userdata.raw
```

固定的 Alpine 包 SHA-256：

```text
rmtfs-1.3-r0.apk         a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4
rmtfs-openrc-1.3-r0.apk  5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769
rmtfs-udev-1.3-r0.apk    09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7
```

仅在未注入 SSH 公钥的基准生成中，机主本地 raw SHA-256 为
`596b37a306397be06538705db979beed0747bf939745104fa0f452ac7bcc488f`，
sparse SHA-256 为
`cc6025bed15d0c6043f657d0b2b8683cc54591cf31bd692f1239c151af426aab`。
注入任意公钥都会按预期改变两个哈希；这时以本次生成的 sidecar 和强校验器为
准。固件完整镜像仍不得公开分发。

## 本机传感器校准

传感器校准不在 Flyme `update.zip` 中，也不能跨设备复制。以下命令只在已经
启动的 M1892 上以 root 身份运行，不是宿主机命令：

```sh
/usr/local/sbin/m1892-persist-sensors-import --check
# 检查通过后按需安装到本机 rootfs：
/usr/local/sbin/m1892-persist-sensors-import --install
```

导入器核对设备型号和分区，以 `ro,noload` 挂载本机 `persist`，绝不写入该
分区；`--install` 只写运行系统中的目标目录。
