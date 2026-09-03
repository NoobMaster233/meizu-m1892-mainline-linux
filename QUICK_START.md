# 懒人安装手册

**简体中文** | [English](QUICK_START_EN.md)

这是当前开发者预览版的最短、可审计安装路径。它不是“一键刷机”：M1892
所需的 Flyme 厂商固件不能随项目分发，因此必须由机主在本地提取一次。

> **会清空手机。** 以下流程彻底擦除 Android `userdata` 并写入 `boot`。
> 仅适用于 Bootloader 已解锁、Fastboot 产品名精确为 `M1892` 的魅族
> 16th Plus。先核验本机救砖资料；不要刷写 GPT、NV、校准、`persist`、
> `proinfo`、`bootbak` 或其他手机的镜像。

## 推荐：Docker/Podman 免编译路径

只有刷机工具、没有 Alpine 编译环境时，先安装 Docker 或 Podman，然后按
[GitHub Actions 与免编译安装](ACTIONS.md)使用与本版本 tag 对应的公开 builder
镜像。它会下载并校验公开 base/boot，在本机容器内从你的 Flyme ZIP 生成、
复验并输出 `m1892-userdata.sparse.img` 和已校验的宿主刷机工具；不会上传
Flyme、公钥或生成物。宿主仍须安装 POSIX shell、Python 3、coreutils 和
Android Platform Tools；准确要求与容器命令见前述链接。

容器完成后直接跳到第 5 节。下面第 1～4 节是等价的本地 Alpine 手工路径，
保留给希望逐步审计或不接受 privileged 容器边界的用户。

## 1. 准备 Alpine 构建机

使用 Alpine Linux edge x86_64，预留至少 35 GiB，并把工作目录放在原生
ext4 文件系统。WSL 可以使用，但必须放在 Linux 家目录，不能放 `/mnt/c`。

以下命令中的 `sudo` 表示已经配置好的提权工具；最小 Alpine 默认可能没有
`sudo`，可先用 `su -` 进入 root shell 执行安装和需要挂载的校验，再回到普通
用户完成下载、源码构建和 `abuild`。

```sh
sudo apk add alpine-sdk android-tools coreutils curl \
  e2fsprogs e2fsprogs-extra \
  findutils git gzip kmod python3 tar unzip util-linux zstd zerofree
e2fs_version=$(e2fsck -V 2>&1 | awk 'NR==1 {print $2}')
test "$(printf '%s\n' 1.47.4 "$e2fs_version" | sort -V | head -n1)" = 1.47.4
git clone https://github.com/NoobMaster233/meizu-m1892-mainline-linux.git
cd meizu-m1892-mainline-linux
git checkout 2026.09-developer-preview.17
mkdir out
```

版本检查失败时必须停止；最低要求是 1.47.4，不要降级到 1.47.3。

## 2. 下载公开镜像

```sh
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fLO "$release/m1892-mainline-base.raw.zst"
curl -fLO "$release/m1892-mainline-base.raw.zst.sha256"
curl -fLO "$release/m1892-mainline-boot.img"
curl -fLO "$release/m1892-mainline-boot.img.sha256"
curl -fLO "$release/m1892-public-kernel.tar.gz"
curl -fLO "$release/m1892-public-kernel.tar.gz.sha256"
curl -fLO "$release/m1892-telephony-audio-runtime.tar.gz"
curl -fLO "$release/m1892-telephony-audio-runtime.tar.gz.sha256"
sha256sum -c m1892-mainline-base.raw.zst.sha256
sha256sum -c m1892-mainline-boot.img.sha256
sha256sum -c m1892-public-kernel.tar.gz.sha256
sha256sum -c m1892-telephony-audio-runtime.tar.gz.sha256
./scripts/verify-m1892-telephony-audio-runtime.sh \
  m1892-telephony-audio-runtime.tar.gz
cp m1892-mainline-boot.img out/m1892-mainline-boot.img
cp m1892-mainline-boot.img.sha256 out/m1892-mainline-boot.img.sha256
zstd -d --long=31 m1892-mainline-base.raw.zst -o out/m1892-mainline-base.raw
printf '%s  %s\n' \
  dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46 \
  out/m1892-mainline-base.raw | sha256sum -c -
```

不要直接刷 `m1892-mainline-base.raw`；它故意不含厂商固件。如果当前
Release 没有该资产及 sidecar，应立即停止。

## 3. 从自己的 Flyme 包生成固件 APK

```sh
./scripts/download-official-flyme.sh --download \
  out/Flyme-8.1.9.0A-update.zip
git clone https://github.com/qca/qca-swiss-army-knife.git out/qca-swiss-army-knife
git -C out/qca-swiss-army-knife checkout 34fa4d6bd6641c79e6a6384816314fbbcd5a23cc
export ATH10K_BDENCODER="$PWD/out/qca-swiss-army-knife/tools/scripts/ath10k/ath10k-bdencoder"
./scripts/extract-flyme-firmware.sh out/Flyme-8.1.9.0A-update.zip \
  out/local-firmware out/m1892-firmware-runtime-20260831.tar.gz
./scripts/build-local-firmware-apk.sh \
  out/m1892-firmware-runtime-20260831.tar.gz \
  out/firmware-meizu-m1892-20260831-r0.apk
./scripts/download-runtime-apks.sh out/alpine-rmtfs-1.3-r0-aarch64
```

这一步必须以普通用户运行；不得把 Flyme、提取归档或生成的固件 APK 上传。

## 4. 生成并验证机主 userdata

快速安装必须注入机主**已经存在**的 SSH 公钥；不要填私钥，也不要为了本项目
另造一把密钥。这样首次启动后才有一条可执行、可审计的管理员入口。

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
./scripts/img2fullsimg.py \
  out/m1892-userdata.raw out/m1892-userdata.sparse.img
./scripts/img2fullsimg.py --verify-against \
  out/m1892-userdata.sparse.img out/m1892-userdata.raw
sha256sum out/m1892-userdata.sparse.img >out/m1892-userdata.sparse.img.sha256
```

必须使用仓库的全 RAW sparse 转换器；普通 `img2simg` 会生成 `DONT_CARE`
区段，不能保证覆盖设备上残留的旧 userdata。

64 GB 与 128 GB 机型使用同一 sparse；首次启动会校验 `/dev/sda19` 并自动
扩展 ext4 到实际 userdata 边界。

## 5. 只读检查，再明确刷写

手机进入 Fastboot 并连接电脑：

```sh
if [ -x out/tools/flash-m1892.sh ]; then
  flash_helper=out/tools/flash-m1892.sh # 推荐容器路径
else
  flash_helper=./scripts/flash-m1892.sh # 第 1～4 节本地仓库路径
fi
"$flash_helper" --check \
  out/m1892-userdata.sparse.img out/m1892-mainline-boot.img
"$flash_helper" --flash ERASE-M1892-USERDATA \
  out/m1892-userdata.sparse.img out/m1892-mainline-boot.img
```

脚本成功后仍停在 Fastboot，再运行 `fastboot reboot`。若 Windows Fastboot
在 userdata 全部分片成功后重新枚举失败，重新进入 Fastboot，只续刷 boot：

```sh
"$flash_helper" --resume-boot FLASH-M1892-BOOT \
  out/m1892-mainline-boot.img
fastboot reboot
```

首次启动较慢，进入桌面后手动连接 Wi-Fi。当前没有 Android 风格的图形化
建号向导；预构建快速路径的默认普通账户为 `m1892`，硬件服务并不依赖这个
名称。图形会话会自动登录；桌面账户属于 `docker` 组，因此能控制 Docker 的
用户实际上拥有等价 root 的主机控制能力。管理员从构建机连接：

运营商中立的蜂窝配置可能在首次启动后自动联网并产生流量；没有合适流量套餐
或处于漫游时，请先拔出 SIM，或进入桌面后立即关闭移动数据。

```sh
ssh root@PHONE_LAN_ADDRESS
```

## 6. 首次启动验收

先执行基础验收命令：

```sh
grep -Fx 'RELEASE_ID="2026.09-developer-preview.17"' /etc/m1892-release
test "$(findmnt -n -o SOURCE /)" = /dev/sda19
test "$(findmnt -n -o FSTYPE /)" = ext4
test "$(cat /sys/fs/ext4/sda19/errors_count)" = 0
m1892-daily-health
docker info >/dev/null
```

Docker 自检会使用本次运行专属的名称创建临时容器、网络、卷、镜像和 `/tmp`
目录，并在退出时清理；不要在有重要 Docker 工作负载运行时执行：

```sh
m1892-docker-selftest
```

只有 `m1892-daily-health` 最后一行出现 `M1892_DAILY_HEALTH_OK`、Docker
自检通过，且桌面实际确认 Wi-Fi、LTE、自动旋转、关屏再唤醒后仍可操作，才算
基础验收通过。电话和短信目前只在一个运营商/SIM 上验收过，必须再用另一台
手机人工验证收发短信、拨入/拨出、铃声、听筒、外放及双向麦克风。若健康检查
失败、出现 ext4/I/O/RCU 错误，或关屏后无法唤醒，应停止日用并按
[安装说明](INSTALL.md)进入 Fastboot 回滚，不要反复强制启动。

完整原理、构建和已知限制见 [安装说明](INSTALL.md)、
[构建说明](BUILD.md) 与 [已知问题](KNOWN_ISSUES.md)。
