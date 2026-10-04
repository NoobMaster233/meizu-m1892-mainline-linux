# 源码与构建

简体中文 | [English](BUILD_EN.md)

本分支提供 Debian 适配及共享内核的源代码。**当前可验证源码契约和独立组件，
尚不能仅靠一次公开 clone 重建完整可刷 Debian 包。** 完整镜像构建仍有旧的本地
Boot/Recovery 输入及运行依赖需要替换为公开可获取、可重建的输入。

```sh
git clone --branch codex/debian13-plasma-mobile \
  https://github.com/NoobMaster233/meizu-m1892-mainline-linux.git
cd meizu-m1892-mainline-linux
python3 tools/verify-source.py .
sh tools/check-source.sh
```

上述检查验证发布内容清单、隐私模式、配置策略、shell 语法、账户状态及容量逻辑，
不会刷写手机，不代表新镜像已经通过真机测试。

源码检查需要 Linux/WSL、Git、Python 3、Bash、常用 GNU 工具、util-linux 的 `unshare`
及 systemd 的 `systemd-sysusers`。账户测试只在隔离的用户命名空间中创建测试账户，
要求宿主允许非特权 user namespace。若出现 `unprivileged-userns`，属于宿主权限
限制；可使用本分支的 GitHub Actions 源码检查，无需修改手机或全局关闭主机安全策略。

源码布局：

- `src/debian/`：Debian 构建脚本、systemd/桌面配置、OEM 初始化、安装器和补丁；
- `src/public-release/`：共用内核、设备树、启动及基础运行组件，保留各自许可证；
- `SOURCE-MANIFEST.sha256`：本次公开源码的文件内容校验；
- `.github/workflows/source-contract.yml`：无需私人设备和凭据的自动源码检查。

内核组件可使用 `src/public-release/scripts/materialize-public-kernel.sh` 和
`build-public-kernel.sh`，遵循其输入校验；现有基线要求 AArch64 GCC 11.4。
Debian 根文件系统使用固定快照、mmdebstrap 与 ARM64 原生执行或 QEMU。
Gamescope/MangoApp 的原生 ARM64 构建入口在 `src/debian/scripts/`。

完整系统还需要传感器/媒体依赖、Plasma Settings、IMS/音频运行库、对应内核模块、
启动器及用户本地厂商固件。部分旧组装器仍会要求内部历史产物哈希，因此目前不提供
声称可以从头执行完成的镜像命令串。请勿删除这些检查、伪造元数据或上传私人输入
来使构建表面通过。请等待匹配的完整构建入口及安装资产发布。
