# V2bX Xray Geo 文件自动更新器

为标准 V2bX 安装提供 `geoip.dat` 和 `geosite.dat` 的定期更新。安装后由 systemd timer 自动维护，不修改 V2bX 核心程序。

## 软件安装

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/GinGer0408/v2bx-geofile-update/main/install.sh && bash install.sh
```

安装脚本需要以 `root` 身份运行。

## 更新策略

- 每天北京时间凌晨 4:00 自动检查更新。
- 使用 v2rayN 兼容的 `geoip.dat`、`geosite.dat` 最新版本。
- 两个文件全部下载并校验成功后才替换现有文件。
- 下载或校验失败时保留原文件，不切换到其他源。
- 替换前保留上一版本；V2bX 重启失败时自动回滚。
- 文件发生变化后才重启 `V2bX.service`。

## 管理命令

```bash
v2bx-geo status      # 查看定时器状态
v2bx-geo update      # 立即手动更新
v2bx-geo log         # 查看更新日志
v2bx-geo version     # 查看脚本版本
v2bx-geo uninstall   # 卸载自动更新任务
```

## 文件位置

```text
/etc/V2bX/geoip.dat
/etc/V2bX/geosite.dat
/etc/systemd/system/v2bx-geo-update.timer
/var/backups/V2bX-geo/
```

适用于使用 systemd、服务名为 `V2bX.service` 的标准 V2bX 部署。
