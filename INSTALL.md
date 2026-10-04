# 安装与恢复

简体中文 | [English](INSTALL_EN.md)

当前 Debian 分支只有源码，没有可推荐给普通用户的最新完整刷机包。
请暂时保留当前可启动系统，不要把源码 ZIP 当作刷机 ZIP，也不要刷入旧
postmarketOS Release 的 Boot 来启动 Debian。

同版本完整包开放后，普通用户请直接按[中文安装手册](PACKAGE_INSTALL.md)操作：
备份 → 下载及校验 → Fastboot → 运行安装器 → 首次账户设置。
不需要进入源码目录或自行编译；[备份与回退准备](BACKUP.md)说明安装前要保留哪些文件。

完整安装需要已解锁的 M1892，且会清除 userdata。Bootloader 解锁并未包含在本项目中。
必须保留原厂 boot/recovery 和设备唯一数据的离线备份。
GPT、ABL、modem/NV、persist、proinfo、校准分区不属于安装写入范围。

源码中的 Windows 安装器采用独立 RAM 安装环境：校验设备及资产，完整传输 userdata，
写入后读回，检查 ext4，按分区实际容量扩容，再安装配对 Boot/Recovery。
它目前仍要求本地组装的完整资产；其存在不代表任意来源的镜像都能安全安装。
**不要自行改成通用 `fastboot flash userdata` 流程。**

未来可下载包的首次开机将通过 Calamares 创建用户名及密码，再进入 Plasma 的
语言、时区、网络与显示向导。它不会提供预置个人账户或通用密码。

若正在使用本项目旧系统，请使用与已安装版本配套的恢复说明与回滚产物。
安装过程中不要混用其他版本的 Boot、Recovery、userdata 或校验文件。
