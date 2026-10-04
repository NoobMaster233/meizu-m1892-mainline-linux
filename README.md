# 魅族 16th Plus：Debian 13 + Plasma Mobile

简体中文 | [English](README_EN.md)

这是魅族 16th Plus（Fastboot 产品名 `M1892`、骁龙 845）的社区主线 Linux
适配源码，使用 Debian 13、Plasma Mobile、systemd 和 Freedreno 图形驱动。
只支持 M1892，不能用于名称相似的其他魅族手机。

**[完整安装包（预发布）](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/tag/debian13-2026.10-preview.1)**
已提供预编译系统、Windows 安装器及校验文件，无需自行编译。
离线检查已通过；此完整包尚未完成真机全新安装验收，仅供有备份及恢复能力的用户测试。
请勿把本仓库其他 Release 中的 postmarketOS 镜像与本分支混用。

- [功能与限制](KNOWN_ISSUES.md)
- [安装与恢复](INSTALL.md)
- [完整包安装流程](PACKAGE_INSTALL.md)与[备份准备](BACKUP.md)
- [源码、构建和可复现性](BUILD.md)
- [隐私与固件说明](PRIVACY.md)
- [旧 postmarketOS 产品线](https://github.com/NoobMaster233/meizu-m1892-mainline-linux/tree/main)

目前在一台 128 GB 手机上已有桌面、触控、硬件图形加速、自动旋转、Wi-Fi、
蓝牙、LTE 数据、短信、通话音频、媒体播放与录音、USB Host 和 Docker 的测试记录。
具体场景和限制见功能说明；这些真机结果不等于此源码快照已完成新的全量安装验收。
尚无第二台手机或 64 GB 实机验收，当前不承诺 Android 等级的可靠性与续航。

镜像应通过首次启动向导创建用户。公开内容不包含作者的账户、密码、SSH 密钥、
Wi-Fi 配置、设备唯一身份、游戏、Steam 库或应用登录状态。
GPU 超频降压属于单台设备实验，公共默认保留 710 MHz。

本项目不隶属于魅族、Debian 或 KDE。各组件保留原有许可证，见
[许可证说明](LICENSES.md)。
