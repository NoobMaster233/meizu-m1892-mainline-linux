# M1892 wiliwili Venus H.264 补丁

本目录保存 Debian 13 / Plasma Mobile 本地 wiliwili Flatpak 的可复现源码修改。它不是
公开直装镜像的一部分，也不包含机主账号、网络配置或 B 站登录数据。

## 基线与补丁顺序

- wiliwili：`v1.6.0`，commit `88e5876bea9502d06f46a8656e3530684d3aaf7d`；
- mpv：`v0.41.0`；
- FFmpeg：`n7.1.3`；
- Flatpak runtime/SDK：`org.freedesktop.Platform/Sdk 25.08`，`aarch64`。

补丁职责：

1. `ffmpeg-7.1-v4l2m2m-decoder-framerate.patch`：V4L2 M2M decoder 用标准
   `VIDIOC_S_PARM` 报告 `timeperframe`；
2. `ffmpeg-7.1-v4l2m2m-drm-prime.patch`：基于 FFmpeg 邮件列表的 V4L2 M2M
   DRM_PRIME 系列，用 `VIDIOC_EXPBUF` 导出 Venus capture DMA-BUF，并补齐失败清理与
   device/frame context 释放；flush 使用标准 output queue STREAMOFF/STREAMON 和
   decoder START 重置，不能等待 renderer 尚未释放的 DRM_PRIME capture 引用，否则
   seek 会让解码线程与呈现线程互相等待；
3. `mpv-0.41-propagate-container-framerate.patch`：在 codec headers 导入完成后、
   `avcodec_open2()` 之前把可信容器帧率写入 `AVCodecContext.framerate`；
4. `wiliwili-1.6-flatpak-private-ffmpeg.patch`：把上述私有 FFmpeg/mpv 纳入上游 Flatpak
   manifest，并在当前 ARM AppStream 环境中使用现有 PNG 图标；
5. `wiliwili-1.6-libmpv-present-timing.patch`：libmpv 回调只设置原子待处理标志，Borealis
   UI 帧合并消费 client event 和 render update；离屏 FBO 不再伪报 display swap，并用
   libmpv 正式参数禁止在 GUI render 调用内等待目标时刻。

不得把 mpv 帧率赋值移回 `mp_set_avctx_codec_headers()` 之前：
`avcodec_parameters_to_context()` 会把它覆盖成 codecpar 的空帧率。

## 构建

必须递归取得 wiliwili 的全部 submodule；尤其 borealis 固定的 GLFW
`892256c3f630739fb02552544b8d83240883ec8a`。缺少该目录时 CMake 会在
`library/borealis/library/lib/extern/glfw` 失败，不能把失败误判为硬解补丁问题。

在干净的 v1.6.0 源码树中：

```sh
mkdir -p m1892-patches
cp /path/to/this-directory/*.patch m1892-patches/
patch -p1 <m1892-patches/wiliwili-1.6-flatpak-private-ffmpeg.patch
flatpak-builder --user --arch=aarch64 --jobs=1 \
  --disable-updates --force-clean --repo=repo build .flatpak-manifest.yml
flatpak build-bundle repo wiliwili-m1892-venus-aarch64.flatpak \
  cn.xfangfang.wiliwili master
```

M1892 只有约 7.4 GiB 内存且默认无 swap。wiliwili Unity C++ 单元峰值可超过 2 GiB；
真机原生构建推荐 `--jobs=1`。只有确认空闲内存和 swap 后才能提高并发。温度散热不能解决
OOM。FFmpeg 和 libmpv 的成功缓存可以复用，但缓存命中不能替代最终 bundle/安装核验。

## 运行配置与验收

owner 的 Flatpak 配置目录使用同目录上级的
[`mpv.conf`](../../userspace/wiliwili/mpv.conf)，只保留：

```ini
vd=h264_v4l2m2m
hwdec=v4l2m2m
```

`hwdec=v4l2m2m` 是补丁后 decoder wrapper 向 mpv 暴露的内部 DRM_PRIME 方法名，不是
软件解码。60 fps 验收不得只凭方法名；至少同时确认：

- 进程持有实际 `qcom-venus` decoder 节点；
- decoder/VO 格式均为 `drm_prime[nv12]`，日志确认 EGL DMA-BUF interop；
- 日志包含 `Decoder timeperframe: 1/60`；
- `video_cc_vcodec0_core_clk` 从约 100 MHz 自动升至约 200 MHz，结束后回落；
- 播放中执行 seek 后出现新的 playback restart，帧回调和画面继续推进；
- 真实窗口 output drop 不持续增长，并由机主完成肉眼流畅度复核；
- 没有 Venus timeout、IOMMU/GPU fault、OOM 或文件系统错误。

锁定高频、pidfd ioctl helper、LD_PRELOAD 忽略 `report_swap()`、显示刷新率伪造和软件
解码均不是接受实现。完整因果证据见
[`../../evidence/wiliwili-flatpak-venus-h264-20260916.md`](../../evidence/wiliwili-flatpak-venus-h264-20260916.md)。
