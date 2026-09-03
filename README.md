# 魅族 16th Plus（M1892）主线 Linux

**简体中文** | [English](README_EN.md)

这是面向魅族 16th Plus（`M1892`，骁龙 845）的实验性
postmarketOS/Phosh 与主线 Linux 移植，当前内核为 Linux 7.1-rc1。

当前公开版本是 [`2026.09-developer-preview.17`](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/tag/2026.09-developer-preview.17)。
一台 128 GB 设备已完成全新安装、自动扩容、桌面、5 GHz Wi-Fi、LTE 数据、
蓝牙、振动、扬声器、实体按键、自动旋转、模拟器、Docker、冷启动和自动
健康检查，以及单一运营商/SIM 下的短信、来电、去电、铃声、听筒、外放和
上行麦克风。
尚无独立第二台设备及 64 GB 实机验收，因此这是**开发者预览版**，不是
稳定版。各项能力的准确边界见[发布状态](PUBLICATION_STATUS.md)和
[已知问题](KNOWN_ISSUES.md)。

## 公开资产

- boot：`m1892-mainline-boot.img`，SHA-256
  `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526`；
- 无厂商固件基础镜像：`m1892-mainline-base.raw.zst`，1,808,945,214 bytes，
  SHA-256 `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad`；
- 解压后的 raw：8,589,934,592 bytes，SHA-256
  `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`；
- 同次干净构建的内核/DTB/音频模块包：`m1892-public-kernel.tar.gz`，
  14,779,794 bytes，SHA-256
  `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c`；
- 开源电话界面依赖包：`m1892-telephony-apks.tar.gz`，5,677,559 bytes，
  SHA-256 `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b`；
- Alpine 无线电运行依赖：`rmtfs-1.3-r0.apk`（13,759 bytes，SHA-256
  `a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4`）、
  `rmtfs-openrc-1.3-r0.apk`（2,162 bytes，SHA-256
  `5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769`）和
  `rmtfs-udev-1.3-r0.apk`（2,164 bytes，SHA-256
  `09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7`）；
- 从固定源码重建的 M1892 通话/IMS/短信运行包（包含 SMS-over-IMS
  ModemManager 补丁）：
  `m1892-telephony-audio-runtime.tar.gz`，2,780,958 bytes，SHA-256
  `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf`；
- 对应通话运行包源码：`m1892-telephony-audio-source.tar.gz`，6,885,734
  bytes，SHA-256
  `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843`；
- 源码归档：`m1892-mainline-source.tar.gz`；以同一 Release 中的
  `.sha256` sidecar 为准。

基础镜像只是 **userdata 构建输入，不能直接刷写**。每位机主必须从自己下载
的 Flyme 8.1.9.0A 官方包中本地提取固件，再生成自己的 userdata。仓库和
Release 不提供 Flyme 固件、固件完整 userdata、原厂 recovery tail、设备
日志、ROM、私人密钥或网络凭据。

## 从这里开始

- [懒人安装手册（推荐）](QUICK_START.md)
- [详细安装与回滚](INSTALL.md)
- [固件提取说明](FIRMWARE.md)
- [已知问题](KNOWN_ISSUES.md)
- [构建说明](BUILD.md)
- [GitHub Actions 与免编译安装](ACTIONS.md)
- [发布状态](PUBLICATION_STATUS.md)
- [许可证](LICENSES.md)
- [本版本发布说明](RELEASE_NOTES.md)

## Docker 快速验收

桌面用户可以直接使用 Docker。下面的命令会从本机 BusyBox 和 musl 临时生成
一个 arm64 测试镜像，并测试网络、DNS、卷、资源限制、端口映射、Compose 和
Buildx；无需预置容器镜像，测试资源退出时会自动清理：

```sh
m1892-docker-selftest
```

需要图形管理界面时，可选安装 Flathub 的原生 aarch64 应用 Pods。基础镜像也
不预装 Flatpak，因此不会给不需要图形容器管理器的用户额外增加约 2.4 GiB 的
GNOME 运行时。在 root 管理终端中执行：

```sh
apk add flatpak
flatpak remote-add --system --if-not-exists flathub \
  https://flathub.org/repo/flathub.flatpakrepo
flatpak install --system flathub com.github.marhkb.Pods
```

若在当前 Phosh 会话启动后才安装，应用抽屉可能暂时看不到新图标。正常注销并
重新登录（开发镜像可重启一次）即可刷新 Flatpak 的标准应用导出目录；这不是
安装失败，也不需要重刷 boot 或 userdata。

## 安全摘要

- 仅适用于 Fastboot 产品名精确为 `M1892` 且 Bootloader 已解锁的设备。
- 安装会彻底清除 Android `userdata` 并写入 `boot`。
- 绝不写 GPT、modem/NV、校准、`persist`、`proinfo` 或 `bootbak`。
- 安装前必须核验本机原厂 boot/recovery 和设备唯一救砖资料。
- 先显式运行 `flash-m1892.sh --check`；写入还需要完整确认令牌。
- 当前桌面自动登录；`docker` 组具有等价 root 的主机控制能力。

本项目属于社区研究，与魅族、postmarketOS 和 Linux 内核项目均无隶属关系。
