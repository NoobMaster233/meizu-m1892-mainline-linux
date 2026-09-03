# 安装说明

**简体中文** | [English](INSTALL_EN.md)

当前版本是开发者预览版。一台 128 GB 设备已完成全新安装、自动扩容、桌面、
Wi-Fi/LTE、冷启动和自动健康检查；这不代表每个当前资产都完成了同等范围的
全硬件复测。尚无独立第二台设备及 64 GB 实机验收。

## 前提条件

1. Fastboot 产品名精确显示为 `M1892` 的魅族 16th Plus。
2. Bootloader 已解锁。
3. 已核验自己的原厂 boot/recovery，以及设备唯一 NV、校准和救砖备份。
4. Google Android platform-tools、原生 Linux 文件系统中的临时空间，以及
   e2fsprogs 1.47.4 或更高版本。
5. 自己下载的 Flyme 8.1.9.0A 官方包；不要使用别人提取的固件或 userdata。

本项目不负责解锁 Bootloader，也不分发原厂分区或 Flyme 私有固件。

## 安装会改写什么

仅允许写入：

```text
userdata  postmarketOS ext4 根文件系统（Android 用户数据全部清除）
boot      M1892 EDK2 + 主线 Linux boot
```

脚本绝不写 recovery、GPT、modem/NV、校准、`persist`、`proinfo`、
`bootbak` 或其他分区。

## 生成机主本地 userdata

先校验 Release 中实际提供的压缩镜像和公开内核包 sidecar，再解压并用文档
固定的 raw 哈希校验解压结果：

```sh
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
```

raw 必须是 8,589,934,592 bytes，SHA-256 必须为
`dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`。
按照[厂商固件说明](FIRMWARE.md)从自己的 Flyme 包生成固件 APK，再运行：

```sh
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
```

快速安装要求使用机主已经存在的**公钥**文件，不得指向私钥，也不要为项目
另造密钥。root 与普通用户的密码登录保持锁定；公开基础镜像和源码归档不含
机主公钥，只有本地生成的 userdata 会写入它。

转换为 Android sparse 后，必须逐字节对照原始 raw：

```sh
./scripts/img2fullsimg.py \
  out/m1892-userdata.raw out/m1892-userdata.sparse.img
./scripts/img2fullsimg.py --verify-against \
  out/m1892-userdata.sparse.img out/m1892-userdata.raw
sha256sum out/m1892-userdata.sparse.img >out/m1892-userdata.sparse.img.sha256
```

转换器只生成 RAW chunk，确保旧 userdata 每个字节都被覆盖；不要改用会产生
`DONT_CARE` 的普通 `img2simg`。校验过程流式比较，不再额外写一份 8 GiB
roundtrip 文件。不要直接刷无固件基础镜像。

## 刷写前只读检查

```sh
./scripts/flash-m1892.sh --check \
  out/m1892-userdata.sparse.img \
  out/m1892-mainline-boot.img
```

它检查单一设备、产品名、解锁状态、8 GiB 全 RAW sparse、64 MiB boot 和两份
sidecar，不写入也不重启。

## 刷写与断点续刷

```sh
./scripts/flash-m1892.sh \
  --flash ERASE-M1892-USERDATA \
  out/m1892-userdata.sparse.img \
  out/m1892-mainline-boot.img
```

脚本先写 userdata，再写 boot，并停留在 Fastboot。Windows Fastboot 可能在
userdata 的全部传输分段均成功后重新枚举失败；重新进入 Fastboot 后只续刷 boot：

```sh
./scripts/flash-m1892.sh \
  --resume-boot FLASH-M1892-BOOT \
  out/m1892-mainline-boot.img
fastboot reboot
```

## 首次启动与账户

首次启动会验证设备型号、`/dev/sda19` 的分区号/名称、发布 UUID 和最小
8 GiB 容量，然后把 ext4 在线扩展至实际 userdata 边界。因此 64 GB 与
128 GB 型号使用同一 sparse。

完整源码构建应在 `pmbootstrap install` 前使用标准
`pmbootstrap config user` 与 `pmbootstrap config hostname` 选择账户。
预构建基础镜像快速路径包含默认普通账户 `m1892`，但硬件服务不会以该名称
作为运行锚点；服务动态解析实际图形会话。当前没有 Android 风格的图形化
首次创建账户向导。图形会话自动登录；桌面账户属于 `docker` 组，所以能控制
Docker 的用户拥有等价 root 的主机控制能力。管理员入口是构建时注入的公钥：

```sh
ssh root@PHONE_LAN_ADDRESS
```

首次进入桌面后手动连接 Wi-Fi。只有授权 shell 中的健康检查、扩容证据、
Wi-Fi/LTE 和重启/挂起门槛全部通过后，才算安装验收完成。

## 回滚

安装前必须已经从**这台手机**取得原厂 boot/recovery 和设备唯一救砖资料，
并把哈希离线保存：

```sh
sha256sum owner-stock-boot.img owner-stock-recovery.img >owner-stock.sha256
sha256sum -c owner-stock.sha256
```

本项目没有通用的无 root 备份工具，也不能从公开包恢复 NV/校准。回滚时仅在
哈希仍匹配且 Fastboot 产品为 `M1892` 时写回本机镜像：

```sh
fastboot getvar product
fastboot flash boot owner-stock-boot.img
fastboot flash recovery owner-stock-recovery.img
fastboot reboot recovery
```

随后由原厂 recovery 重建 Android userdata。不要使用其他手机的镜像；若没有
这些已验证备份，应在安装前停止，而不是把公开 Release 当成救砖包。
