# 魅族 16th Plus：预编译本地直装包

[English](README_EN.md)

> 在 GitHub 源码目录阅读时：这是完整本地安装包所用的说明模板；当前源码目录
> 不含镜像，不能直接刷机。请先查看仓库首页和安装说明确认是否已有匹配的可用包。

**这是机主本地完整包，不是允许公开再分发的 Release。** 包含从机主官方 Flyme 包
提取的机型固件，不包含机主账户、Wi-Fi、SSH key、设备唯一校准或游戏。
尚未核实所有厂商文件的再分发授权前，请不要上传或转发整个 ZIP。
本地验收版保留 USB root 开发控制台，且自动深度休眠仍关闭；请不要连接不信任的电脑。
这是明确的研发配置，不等于完成安全与耗电收尾的公开日用版本。

## 安装

只适用于已经解锁 Bootloader 的 **魅族 16th Plus / M1892**，不是 16th。
安装会擦除整个 userdata，包括 Android/Linux 文件、游戏和存档。
事先保存官方包不能恢复的设备唯一数据，并准备离线恢复环境。

1. 在 Windows 解压全部文件。安装官方 [Google platform-tools](https://developer.android.com/tools/releases/platform-tools)，
   将其中整个 `platform-tools` 文件夹放在 `install.cmd` 旁边；也可将 fastboot 加入 PATH。
2. 手机进入 Fastboot，以数据线直接连接电脑；断开其他手机。
3. 双击 `install.cmd`。按提示输入 `ERASE-M1892-USERDATA` 确认删除。
4. 不拔线。安装器自动加载 RAM 安装环境，流式写入、完整读回、检查文件系统、
   按实际容量扩容，并安装配对 Boot/Recovery 后重启。
5. 在手机完成首次账户初始化，选择自己的用户名和密码，然后连接自己的 Wi-Fi。

账户创建后还会出现 Plasma 官方的时间、网络、缩放与导航向导；它不是第二次创建账户。
系统直接使用 Debian/KDE 原始启动程序，向导、桌面和其他应用统一使用默认 FD630
硬件加速。部分缩放下向导页面切换可能出现介绍文字残影，属于已知 Qt Quick 重绘问题。

不需要 Linux、Docker、内核编译或手动固件提取。支持 Windows 自带 USB NCM/ACM
驱动的环境；Fastboot 驱动需事先正常工作。

## 故障恢复

保留安装文件，失败后不要盲目擦除任何其他分区。RAM 阶段没有通过时，不会开始写 userdata。
若安装中断，按电源键与音量减回 Fastboot，然后重新运行安装器；重复安装仍会删除 userdata。
若已完整安装 userdata、仅最后 Boot/Recovery 刷写失败，可在 Fastboot 手动执行：

```powershell
.\platform-tools\fastboot.exe flash recovery .\m1892-system-recovery.img
.\platform-tools\fastboot.exe flash boot .\m1892-system-boot.img
.\platform-tools\fastboot.exe reboot
```

安装器不修改 GPT、ABL、modem/NV、persist、proinfo 或设备校准。
RAM 安装 Boot 不是正常日用 Boot，不能单独刷完后当作安装完成。
64 GB/128 GB 通过实际 userdata 分区容量识别，不重新分区。
128 GB 已做真机验证；64 GB 目前只有离线几何证明，尚未实机验证。
相机与省电收尾不属于本安装包的完成声明；重新安装后的账户输入、声音与实体外设
仍需按真实操作验证，不能仅凭安装器返回成功认定全部日用功能通过。
