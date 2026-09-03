# 公开发布状态

**简体中文** | [English](PUBLICATION_STATUS_EN.md)

版本：`2026.09-developer-preview.17`（开发者预览版，不是稳定版）

## 已发布并核验

- boot：`m1892-mainline-boot.img`，SHA-256
  `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526`；
- 基础镜像：`m1892-mainline-base.raw.zst`，1,808,945,214 bytes，SHA-256
  `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad`；
- 解压 raw：8,589,934,592 bytes，SHA-256
  `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46`；
- 内核/DTB/音频模块包：`m1892-public-kernel.tar.gz`，SHA-256
  `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c`；
- 电话界面依赖归档：`m1892-telephony-apks.tar.gz`，SHA-256
  `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b`；
- Alpine `rmtfs`、`rmtfs-openrc`、`rmtfs-udev` 三个固定版本 APK；其大小与
  SHA-256 见 [README](README.md)，并由下载脚本逐个强校验；
- 固定源码构建的通话/IMS 运行包：`m1892-telephony-audio-runtime.tar.gz` 及
  `.sha256` sidecar，SHA-256
  `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf`；
- 通话运行包对应源码：`m1892-telephony-audio-source.tar.gz`，6,885,734
  bytes，SHA-256
  `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843`；
- 源码归档 `m1892-mainline-source.tar.gz` 及各资产 sidecar；归档自身的哈希以
  同一 Release 中的 `.sha256` 为准；
- `m1892-owner-builder.digest`：记录免编译工具容器不可变的 GHCR manifest
  digest；用户不得以可覆盖 tag 代替；
- 一台 128 GB 设备已验收全新安装、自动扩容、桌面、5 GHz Wi-Fi、LTE 数据、
  蓝牙、振动、扬声器、实体按键、自动旋转、模拟器、Docker、冷启动和自动
  健康检查，以及单一运营商/SIM 下的短信、来电、去电和双向通话音频；
- Docker 29.7.2 已验收默认桥 DNS/出网、自定义网络 DNS、命名卷、bind mount、
  内存限制、端口映射、Compose 和普通桌面用户访问；
- 公开源码已通过隐私、私有文件、许可证、链接和源码清单检查。

基础镜像不含厂商固件、机主密钥或网络凭据，不能直接刷写。固件完整 userdata
和带原厂 tail 的 recovery 不属于公开资产。

从固定公开 base、机主自己的 Flyme 包和 Release 运行包生成可刷 userdata 的
路径已经公开且可独立验证；这与“从空目录逐包重建出字节相同的 base”是两个
不同范围，后者仍列在尚未完成项中。

## 尚未完成

- 独立第二台设备/用户验收及 64 GB 实机验收；
- 当前版本对所有硬件功能的完整人工复测；
- 其他运营商/SIM 的 IMS/VoLTE 与短信兼容性、通话静音、紧急呼叫和屏下指纹；
- 内核、模块、System.map 与 EDK2 的跨宿主逐字节确定性（功能与 ABI 验收已
  由 Actions 覆盖）；
- 公开 base 从空目录逐包重建的完整路径。

详细限制见 [已知问题](KNOWN_ISSUES.md)，当前资产与验收边界见
[发布说明](RELEASE_NOTES.md)。完成独立设备验收前不得标记 stable。
