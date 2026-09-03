# GitHub Actions 与免编译安装

**简体中文** | [English](ACTIONS_EN.md)

GitHub Actions 可以自动校验公开源码，并从固定源码重建公开内核、EDK2 与
通话/IMS 用户态组件。它不能安全地替机主生成最终 userdata 或直接刷手机：M1892 所需的
Flyme 固件不可公开分发，Actions 手动输入也不是多 GiB 文件上传通道，云端
runner 更无法访问用户电脑上的 USB Fastboot 设备。

## 仓库提供的工作流

- `Public source contract`：每次 push/PR 自动运行公开树、隐私、许可证、脚本
  语法、源码 manifest 和确定性归档检查；
- `Build public components`：在 Actions 页面手动选择 `kernel`、`edk2`、
  `telephony-audio` 或 `all`，从固定提交重建并校验公开组件；通话任务还会
  生成对应源码包，短期 artifact **不是可刷镜像**；
- `Publish owner builder image`：维护者手动构建不含 Flyme 的 GHCR 工具容器，
  并把不可变镜像摘要写入已有的草稿 Release。

普通校验和组件构建只有 `contents: read`；仅 builder 发布工作流具有发布
容器和向草稿 Release 附加摘要所需的写权限。

## 在自己的 Fork 中云端重建公开组件

普通用户不能在维护者仓库中随意触发手动工作流。需要先 Fork 本仓库，在自己
的 Fork 中打开 **Actions**，启用工作流，然后选择 **Build public components**
和 **Run workflow**，按需选择 `kernel`、`edk2`、`telephony-audio` 或 `all`。成功后可在该次运行
页面下载保留 7 天的构建 artifact。

artifact 只包含从固定公开源码重建并通过校验的内核、EDK2、通话用户态组件
及其对应源码，用于审计和开发；它不是完整 userdata，也不能跳过下面的机主
本地固件生成步骤。

## 普通用户：本地免编译生成 userdata

宿主机仍需 POSIX shell、Python 3、`sha256sum`、`timeout` 和 Android
Platform Tools（必须包含 `fastboot`）；容器只免去 Alpine SDK 和内核编译
环境，不会替宿主访问 USB。安装这些基础刷机工具及 Docker/Podman 后，新建一个空工作目录，并只放入从魅族官方下载的
`Flyme-8.1.9.0A-update.zip` 和自己已有的 SSH 公钥 `id_ed25519.pub`。输出目录
`out` 必须尚不存在。容器已经包含 Alpine、apk、e2fsprogs 和提取工具，不需要
在电脑上编译内核或配置 Alpine SDK。

```sh
release=https://github.com/NoobMaster233/meizu-m1892-mainline-linux/releases/download/2026.09-developer-preview.17
curl -fL "$release/m1892-owner-builder.digest" -o m1892-owner-builder.digest
image="$(cat m1892-owner-builder.digest)"
docker run --rm --privileged --platform linux/amd64 \
  -v "$PWD:/work" \
  "$image" \
  /work/Flyme-8.1.9.0A-update.zip /work/id_ed25519.pub /work/out
```

Podman 使用相同的 digest；在启用 SELinux 的宿主上给挂载增加 `:Z`：

```sh
podman run --rm --privileged --platform linux/amd64 \
  -v "$PWD:/work:Z" "$image" \
  /work/Flyme-8.1.9.0A-update.zip /work/id_ed25519.pub /work/out
```

`--privileged` 仅用于在容器内只读挂载新生成的 ext4 镜像执行第二层完整校验，
但它给予容器很高的宿主权限。Release 提供的是不可变 manifest digest，不能
用可覆盖 tag 代替。不接受
该边界时，按[懒人安装手册](QUICK_START.md)在本地 Alpine 中执行。容器入口
以 root 协调镜像挂载，但 `abuild` 子步骤会强制降权到专用普通用户；发布工作流
同时验证缺参 fail-closed 和这次权限切换。
当前工具镜像发布为 `linux/amd64`；ARM64 宿主必须先启用 amd64 容器仿真。
构建失败时，未完成的临时输出会自动删除，可以直接用同一条命令重试。

容器不会上传 Flyme、公钥或生成物。退出码为 0 且同时出现以下标志，才允许
继续刷写：

```text
M1892_LOCAL_FIRMWARE_IMAGE_PASS
M1892_LOCAL_FIRMWARE_VERIFY_PASS
M1892_FRESH_IMAGE_VERIFY_PASS
M1892_OWNER_BUNDLE_PASS
```

`out/` 中会同时生成 `m1892-userdata.sparse.img`、刷机脚本要求的
`m1892-userdata.sparse.img.sha256`，以及已经过摘要校验的
`out/tools/flash-m1892.sh` 与同目录 `img2fullsimg.py`。无需克隆仓库或手工补摘要。

刷写仍在宿主系统按[安装说明](INSTALL.md)执行，使用
`out/tools/flash-m1892.sh` 先 `--check`，再使用显式擦除令牌。容器不访问
USB，也不跳过设备型号或解锁检查。

## 为什么不在 Actions 上传 Flyme

公开 runner 临时磁盘有限；`workflow_dispatch` 只接收小型结构化输入，不是
文件上传接口。把 Flyme 凭据放入输入/日志，或把含厂商固件的 userdata 上传
为 artifact，会扩大隐私、版权、留存和供应链风险。因此云端只处理可公开的
源码/组件，本地容器只处理机主自己的非公开输入。
