# 魅族 16th Plus：Debian 13 + Plasma Mobile 安装手册

简体中文 | [English](PACKAGE_INSTALL_EN.md)

本手册随同版本完整安装包使用。只下载 Release 附件中的系统 ZIP；GitHub 自动生成的
“Source code”不是刷机包。没有经过实机验收并公开的 Release 时，请勿把候选用于日用设备。

## 1. 确认适用条件

- 手机必须是魅族 **16th Plus，Fastboot 产品名为 M1892**，且 Bootloader 已解锁。
  16th、16s 等其他机型不能使用。解锁不包含在安装器中。
- 使用 Windows 10/11、可靠的数据线；电脑至少留出 5 GB 空间，手机电量充足。
- 先按 [备份与回退准备](BACKUP.md) 保存需要的数据、原有 boot/recovery；已有设备唯一备份应离线保管。
  **安装将删除 userdata 中的全部 Android/Linux 文件、账户、应用、游戏和存档。**
- 保留兼容 Flyme 8.1.9.0A 的原厂 vendor、modem、蓝牙、DSP 数据及原厂 Recovery 尾部。
  安装器会自动读取并验证所需文件；不满足时会在擦除 userdata 前停止。
  最终会重写 **boot、recovery、userdata**；Recovery 使用本机保留并校验的原厂尾部。
  不改写 vendor、modem、蓝牙、DSP、GPT、ABL、NV、persist、proinfo 或校准数据。

无需编译 Linux，也无需配置 WSL、Docker 或手工解包 Flyme 固件。
安装器离线从待刷手机提取其固件；系统包不包含作者的账户、网络、密钥或设备身份。

## 2. 下载并解压

从同一 Release 下载完整 ZIP 和同名 `.sha256` 校验文件。
在 PowerShell 中计算下载文件的校验值，与 `.sha256` 中的值比较：

```powershell
Get-FileHash -Algorithm SHA256 .\m1892-debian13-plasma-mobile-install.zip
```

校验一致后，把 ZIP 完整解压到例如 `C:\M1892`。不要直接在 ZIP 窗口里运行脚本。
目录中应有 `Install.ps1`、`Transport.psm1`、`install.cmd`、`manifest.json`、
安装环境、系统镜像、Boot 和 Recovery 模板；文件缺失时重新解压，不能混用其他版本。

从 [Google 官方页面](https://developer.android.com/tools/releases/platform-tools)
下载 Windows Platform-Tools，将其 `platform-tools` 文件夹放到 `Install.ps1` 旁边，
使 `platform-tools\fastboot.exe` 存在。Windows 还需要能识别手机 Fastboot 的驱动。

## 3. 进入 Fastboot 并确认

手机关机后，使用电源键和音量减键进入 Fastboot，通过数据线直连电脑。
断开其他手机。在包目录打开 PowerShell：

```powershell
.\platform-tools\fastboot.exe devices
.\platform-tools\fastboot.exe getvar product
.\platform-tools\fastboot.exe getvar unlocked
```

应只有一台设备，并显示 `product: M1892`、`unlocked: yes`。
没有设备时先检查数据线、USB 口和驱动；不要继续刷写。

## 4. 安装

先做包内校验（不需要手机，也不刷写）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -VerifyOnly
```

出现 `M1892_PACKAGE_VERIFY_PASS` 后，双击 `install.cmd`。
阅读擦除提示，确认备份完成后输入：

```text
ERASE-M1892-USERDATA
```

此后安装器自动重启到临时安装环境、检查原厂固件、传输和写入系统、读回校验、
按实际分区容量扩容、写入并读回 Boot/Recovery，最后请求重启。
期间 USB 设备会断开并重新出现，请保持线缆连接，不要手工切换到 Recovery 或重复启动脚本。
进度包含大文件传输与文件系统检查，可能需要数分钟。

安装写入成功标志为 `M1892_INSTALL_WRITE_READBACK_PASS`。
这表示写入及读回完成；第一次进入桌面仍需完成下面的账户设置。
如果安装器提示重启确认失败，请先观察手机，不能直接认定镜像没有写入。

## 5. 首次开机

1. 在账户创建页面设置自己的用户名和密码。
2. 按提示重启后，完成 Plasma 的语言、时区、Wi-Fi、显示和导航向导。
3. 默认提供简体中文，英语可在设置中选择。没有通用默认密码。
4. 连接 Wi-Fi，测试触摸、旋转、声音和所需网络功能。

正常系统使用 USB Host，安装时的 USB 调试端口会消失，这是正常现象。
手机会按各自实际 userdata 容量扩容；128 GB 有实机证据，其他容量的限制见 Release。
个人应用登录、Wi-Fi、Steam 游戏和模拟器 ROM 均需自行恢复或安装。

## 6. 出错与恢复

- **校验或机型失败：**停止，不要手工跳过检查。
- **固件或 Recovery 尾部不匹配：**userdata 尚未擦除，但 Boot 可能已换成临时安装器。
  返回 Fastboot，恢复自己预先保存的 Boot；先解决原厂基础分区兼容性，不能强行刷 userdata。
- **传输、读回或文件系统检查失败：**不要拔线或覆盖其他分区。保留控制台错误，
  如需重新安装，返回 Fastboot 后使用同一个完整包；重新安装仍会清除 userdata。
- **系统已经写完，只是重启状态未知：**先等待并检查屏幕；必要时正常重启。
  不要仅因 USB 消失就再次擦除数据。
- **需要恢复旧系统：**使用自己的配套 boot/recovery 和系统备份，或该机型的官方恢复方式。
  仅恢复 Boot 不能找回已经清除的 userdata。

恢复自己的 Boot 的示例（文件必须来自自己的匹配备份）：

```powershell
.\platform-tools\fastboot.exe getvar product
.\platform-tools\fastboot.exe getvar unlocked
.\platform-tools\fastboot.exe flash boot .\original-boot.img
.\platform-tools\fastboot.exe reboot
```

不要直接把包中的 `m1892-recovery-template.bin` 当作 Recovery 刷入；安装器需要结合本机
的原厂尾部生成最终 Recovery。相机、手机级深度休眠和原厂快充等未完成能力仍按
[功能与限制](KNOWN_ISSUES.md) 执行，安装成功不意味着这些能力已完成。
