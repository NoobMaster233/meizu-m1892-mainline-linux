# 2026.09-developer-preview.17 发布说明

**简体中文** | [English](RELEASE_NOTES_EN.md)

这是目前提供给外部测试者的开发者预览包。请仅使用同一 GitHub Release
中的镜像、源码和校验文件，不得跨 Release 混用。

## 公开资产契约

| 资产 | 大小 | SHA-256 |
|---|---:|---|
| `m1892-mainline-boot.img` | 67108864 bytes | `7163a76c11553f5c3614c17e57463e64c9ed107e1384800b69079bb64ef93526` |
| `m1892-mainline-base.raw.zst` | 1808945214 bytes | `fff68a40d6ba78e6a4b20e14143084b055e19be677004333a3573e4309fe28ad` |
| 解压后的 `m1892-mainline-base.raw` | 8589934592 bytes | `dad8ed724ae5d9611ffaa63ccc5b351bdaecbf6303b6167ca8bcde3eea1a6d46` |
| `m1892-public-kernel.tar.gz` | 14779794 bytes | `9bb7faeed12978805779a637cf1f5c124704c5da8a0c87b2467e3806a100127c` |
| `m1892-telephony-apks.tar.gz` | 5677559 bytes | `05427445f48557296df0d79dfb04e3bc3bb086ce295901763e4e49471b0a669b` |
| `rmtfs-1.3-r0.apk` | 13759 bytes | `a28b52494bf42b148f0960732888fec78ab082b68c6fbe499113419e571bc0d4` |
| `rmtfs-openrc-1.3-r0.apk` | 2162 bytes | `5529577df2c25c09f363a2f7ac877368e6a520e62765180677253af42f0a9769` |
| `rmtfs-udev-1.3-r0.apk` | 2164 bytes | `09e8237366b7246080709a4e2a2fe73e567b121db7a0130e8dc3b1e1f1871ad7` |
| `m1892-telephony-audio-runtime.tar.gz` | 2780958 bytes | `31d2edbd8780975ae4c3f556299a807a103ab278b284d0dd7c474a4ba9af88cf` |
| `m1892-telephony-audio-source.tar.gz` | 6885734 bytes | `4790578fb26a5880cb14f52e8f1c37c16e38aed8bd360149096d3e4297417843` |

只有当上表中的全部可下载资产、源码归档及文档要求的 sidecar 均实际出现在
同一 GitHub Release 时，才称本版本已发布。基础 raw 只是无厂商固件的 userdata 构建输入，不能
直接刷写。
Release 还必须包含 `m1892-owner-builder.digest`，用于把懒人安装手册的容器
固定到不可变 GHCR manifest，而不是可覆盖的 tag。

## 当前版本包含

- 可从公开基础包和机主自己的 Flyme 包重建、强校验并刷写一份全新的 userdata；
- 新安装会显式恢复蓝牙设备唯一地址，电话/IMS 实际使用的纯 Python 模块已封装，
  通话音频服务不再依赖目标设备联网补包；
- ModemManager 从固定上游提交重建，并为 LTE/IMS 网络优先设置 QMI WMS
  `SMS on IMS`；基带明确拒绝 IMS 域时只回退一次默认域，兼容 CS 短信；
- USB 连接电脑时兼容实际出现的 475 mA 安全电流上限，不再误判电源策略失败；
- 机主镜像生成步骤会把当前公开的电源与健康检查实现写入镜像并逐字节校验，
  不再继承基础镜像中的旧副本；
- 推荐的机主镜像生成工具会直接生成并复验刷机脚本所需的 sparse 独立摘要文件；
  基础镜像校验脚本也明确区分基础内容与机主镜像生成步骤写入的内容；
- 64/128 GB 共用同一安装镜像，首次启动自动扩容；
- 桌面、5 GHz Wi-Fi、LTE 数据、蓝牙、扬声器、自动旋转、模拟器和 Docker；
- 短信、来电/去电、来电铃声、听筒/外放切换和双向通话音频；
- 快速安装要求注入机主已有 SSH 公钥，密码登录保持锁定；
- GitHub Actions 自动校验公开源码并可重建内核、EDK2 和通话音频公共组件；另提供不含
  Flyme 的本地免编译 builder 容器；
- 刷写前强制检查设备型号、解锁状态、8 GiB 全 RAW sparse、Boot 和摘要；
- 厂商固件与传感器校准只从机主自己的设备/官方包本地取得，不进入 Release。

## 本地机主产物

每位机主生成的固件完整 raw 和 sparse 都只用于自己的设备。它们包含从机主
官方 Flyme 包提取的受版权保护固件，不属于公开 Release，绝不能上传或再分发。

## 验收与可复现性边界

一台 128 GB M1892 已通过完整刷写、首次扩容、桌面、5 GHz Wi-Fi、LTE
IPv4/IPv6、蓝牙、振动、扬声器、实体按键、自动旋转、模拟器、Docker、短信、
来电/去电、来电铃声、听筒/外放切换、双向通话音频、冷启动
和自动健康检查。Docker 已覆盖默认桥、自定义网络 DNS、卷、bind mount、内存
限制、端口映射、Compose 和普通用户访问。仍缺独立第二台设备及 64 GB 实机
验收，因此不能标记 stable。

内核和 EDK2 的源码、提交、配置及输入可以公开审计。Actions 严格验证内核
release、模块 ABI、配置、符号、设备树语义和规范 DTB 哈希，并记录每次构建的
实际二进制哈希；由于编译器/binutils 打包和生成元数据差异，内核、模块、
System.map 与 EDK2 不承诺跨宿主逐字节相同。公开 base 仍缺从空目录逐包重建的
完整路径；输入可审计不等于所有产物都可逐字节重建。

安装前请从 [懒人安装手册](QUICK_START.md) 开始，并阅读
[已知问题](KNOWN_ISSUES.md) 与 [公开发布状态](PUBLICATION_STATUS.md)。
