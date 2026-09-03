# 许可证

**简体中文** | [English](LICENSES_EN.md)

各组件保留各自的上游许可证，尤其包括：

- Linux 内核修改和可加载内核模块：GPL-2.0-only，除非源码头声明其他兼容
  许可证；
- postmarketOS 设备打包：以各文件/软件包声明的许可证为准；
- 本项目编写的 M1892 shell/OpenRC 集成源码：采用随附
  `licenses/MIT.txt` 中的 MIT；发布脚本还带有明确的
  `SPDX-License-Identifier: MIT`；
- EDK2：上游 BSD-2-Clause-Patent 及各组件自己的 notices；
- Phoc 0.56.0 与随附的 M1892 补丁：GPL-3.0-or-later；构建脚本本身为 MIT；
- Alpine/postmarketOS 软件包、Phosh、Mesa、ES-DE、RetroArch 和 PPSSPP：
  采用各自上游许可证；
- `linux-msm/rmtfs` 与 Alpine 官方 `rmtfs` 软件包：BSD-3-Clause。
- 随通话运行时固定并捆绑的 `pyosmocom` 0.0.11：GPL-2.0-or-later；
- 随通话运行时固定并捆绑的 `python-statemachine` 2.5.0：MIT。
- 通话运行时中的 callaudiod：GPL-3.0；
- 通话运行时中的 81voltd：GPL-2.0；
- 通话运行时中的 qcom-imsd：GPL-2.0-or-later；
- 通话运行时中的 ModemManager 主程序：GPL-2.0；其共享库接口部分按
  LGPL-2.1；
- 通话运行时中的 libqmi：工具部分 GPL-2.0、共享库部分 LGPL-2.1。

上述两个纯 Python 依赖从 PyPI 官方文件端点下载，构建脚本会在解包前校验
固定的 SHA-256；wheel 内的许可证与元数据会随运行时一同保留。
callaudiod、81voltd、libqmi、qcom-imsd 和 ModemManager 的上游许可证正文
也会复制到运行时归档的
`/usr/share/licenses/m1892-telephony-audio-runtime/`；项目集成部分的 MIT 正文
也会一同安装，并由归档校验器逐项检查。

源码与许可来源固定在构建脚本记录的提交：

- [callaudiod](https://gitlab.com/mobian1/callaudiod)、
  [81voltd](https://gitlab.postmarketos.org/modem/81voltd)、
  [libqmi](https://gitlab.postmarketos.org/modem/openimsd/libqmi)、
  [qcom-imsd](https://gitlab.postmarketos.org/modem/openimsd/qcom-imsd) 和
  [ModemManager](https://gitlab.freedesktop.org/mobile-broadband/ModemManager)；
- [Linux 内核](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git)、
  [Phoc](https://gitlab.gnome.org/World/Phosh/phoc)、
  [EDK2](https://github.com/tianocore/edk2) 与
  [rmtfs](https://github.com/linux-msm/rmtfs)。

源码归档同时携带 `licenses/` 下的 GPL-2.0、GPL-3.0、LGPL-2.1、
BSD-3-Clause、BSD-2-Clause-Patent 和 MIT 正文；具体文件仍以自身 SPDX 或
上游声明为准。
Release 另附 `m1892-telephony-audio-source.tar.gz`，包含通话运行包对应的固定
上游源码快照、项目补丁、纯 Python 依赖 wheel、构建脚本和许可证。

固件提取器会调用但不捆绑 `qca-swiss-army-knife` 提交
`34fa4d6bd6641c79e6a6384816314fbbcd5a23cc` 中的 `ath10k-bdencoder`；
其源码包含 Qualcomm Atheros 宽松许可声明。请从上游获取该工具并保留声明。

本项目不对魅族/Qualcomm/其他厂商固件、原厂 boot 或 recovery 字节、游戏
ROM、抓取媒体或其他第三方私有内容授予许可证。这些内容均排除在公开仓库和
发布附件之外。

当前压缩基础镜像由构建元数据记录的软件包集合与本项目集成文件
组成。它包含这些软件包已安装的许可证资料和 ES-DE/PPSSPP 许可证/资源树，
但不包含厂商固件、ROM、抓取媒体或设备身份。对应源码可从构建记录固定的
Alpine/postmarketOS 和上游仓库获得。它是构建输入，不是固件完整系统镜像。

许可证与源码指针说明公开边界，但不构成“所有二进制均可逐字节重建”的承诺。
EDK2 跨宿主不保证字节一致，部分交付二进制尚无完整公开从零重建路径；应在
发布元数据中保留精确二进制哈希和相应来源/许可证记录。

每次 GitHub 发布前，生成的源码包必须包含所选组件要求的全部许可证与 notice
文件，并且校验器必须确认不存在私有 payload。
