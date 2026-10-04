# 备份与回退准备

简体中文 | [English](BACKUP_EN.md)

**没有可用的 Boot 回退文件或尚未导出个人数据时，不要运行安装器。**
安装器在固件预检前就会把 boot 临时换成安装环境；“userdata 没有擦除”不代表旧系统
立即还能启动。原 boot/recovery 只用于恢复引导，不能代替照片、文件、应用和存档备份。

## 已有 root 的 Android

先把照片、下载、联系人及需要的应用数据导出到电脑。下面的原始分区读取要求 Android
已有可用的 `su`，不是解锁或获取 root 的教程。只连接目标 M1892，允许自己的电脑使用 ADB，
在 Platform-Tools 目录的 PowerShell 中执行：

```powershell
.\adb.exe devices
.\adb.exe shell "su -c 'id'"
```

只有唯一设备显示 `device`、第二条成功返回 `uid=0`，且已经确认它是自己的 M1892，
才能继续。分区别名不存在、权限失败或命令报错时停止，不要猜数字分区名。
选择一个尚不存在的备份目录名，例如 `M1892-backup-before-linux`：

```powershell
.\adb.exe shell "su -c 'test ! -e /sdcard/M1892-backup-before-linux && mkdir /sdcard/M1892-backup-before-linux'"
.\adb.exe shell "su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/M1892-backup-before-linux/original-boot.img bs=4M'"
.\adb.exe shell "su -c 'dd if=/dev/block/bootdevice/by-name/recovery of=/sdcard/M1892-backup-before-linux/original-recovery.img bs=4M'"
if (Test-Path .\M1892-backup-before-linux) { throw '请选择全新的电脑备份目录' }
.\adb.exe pull /sdcard/M1892-backup-before-linux .\M1892-backup-before-linux
.\adb.exe shell "su -c 'sha256sum /sdcard/M1892-backup-before-linux/original-boot.img /sdcard/M1892-backup-before-linux/original-recovery.img'"
Get-FileHash -Algorithm SHA256 .\M1892-backup-before-linux\*.img
```

每条命令均须成功。确认电脑上的两个完整分区镜像各为 67,108,864 字节，再记录本地
SHA-256，并与手机输出逐一比较；若大小或校验不同请停止核实。`su` 的授权和参数可能因现有 Android 方案而异，
不支持这些命令时不能把失败或空文件当作备份成功。

## 已在运行 Linux

在手机自己的普通用户终端执行（`sudo` 使用自己设置的密码）：

```sh
mkdir "$HOME/M1892-backup-before-linux"
sudo dd if=/dev/disk/by-partlabel/boot of="$HOME/M1892-backup-before-linux/original-boot.img" bs=4M status=progress
sudo dd if=/dev/disk/by-partlabel/recovery of="$HOME/M1892-backup-before-linux/original-recovery.img" bs=4M status=progress
sudo chown -R "$(id -u):$(id -g)" "$HOME/M1892-backup-before-linux"
sha256sum "$HOME/M1892-backup-before-linux/"*.img
```

通过自己已经配置的 SSH/SFTP 或文件传输方式把整个目录复制到电脑；对电脑副本再次
计算 SHA-256，并与手机结果比较。不要把仍只保存在手机上的备份算作完成，因为 userdata 会被清除。

## 只有 Fastboot、没有可读取当前系统的权限

本项目不声称 M1892 的旧 Fastboot 支持读取任意分区。请先取得匹配当前系统的
可恢复 Boot/Recovery 或可靠备份，再继续；不能用安装器中的临时 Boot 充当旧系统备份。
原厂系统的恢复资料请以 [Flyme 官方 M1892 固件页面](https://www.flyme.com/firmwarelist-175.html)
为入口。官方包不能恢复设备唯一身份，也不能恢复已经清除的个人数据。
非原厂 Linux/定制 ROM 应保留其自己的安装与恢复包，不把原厂 Boot 当作通用回退。

## 设备唯一数据与保管

已经拥有的 persist、modemst、fsg/fsc、private、proinfo 等本机备份应离线保管，
不要上传 GitHub、论坛或聊天。它们可能包含无线身份、校准或设备状态。
本安装器不写这些分区，也不提供通用 EDL/Firehose 恢复；没有匹配工具和明确方案时，
不要尝试把别人的备份或原始分区镜像写入自己的手机。

回退命令与安装失败处理见 [安装手册](PACKAGE_INSTALL.md)。
