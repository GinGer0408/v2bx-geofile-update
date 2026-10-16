# V2bX Xray Geo 文件自动更新器

为标准 V2bX 安装提供 `geoip.dat` 和 `geosite.dat` 的定期更新。安装后由 systemd timer 自动维护，不修改 V2bX 核心程序。

## 软件安装

### 一键安装

```bash
wget -N https://raw.githubusercontent.com/GinGer0408/v2bx-geofile-update/main/install.sh && bash install.sh
```

安装脚本需要以 `root` 身份运行。当前脚本版本为 `1.3.0`。

适用于 systemd 正在运行、服务名为 `V2bX.service` 的标准 V2bX 部署，不支持 Alpine/OpenRC。依赖 Bash、curl、coreutils（含 sha256sum）、util-linux（含 flock）和 tzdata。安装脚本可自动安装 curl；缺少其他工具时会提示并退出。

## 更新策略

- 每天北京时间凌晨 4:00 自动检查更新。
- 定时任务显式使用 `Asia/Shanghai`；状态、日志和文件时间统一显示北京时间，不修改 VPS 系统时区。启用 `Persistent=true`，关机期间错过的更新可在开机后补执行。
- 使用 v2rayN 兼容的 `geoip.dat`、`geosite.dat` 最新版本。
- 两个文件全部下载并校验成功后才替换现有文件。
- 使用上游发布的 `.sha256sum` 文件核对 SHA-256；校验文件获取失败也会中止更新。
- 一次检查固定一个上游发布版本，Geo 数据和校验文件不会跨版本混用。
- 更新、自更新、卸载和重载任务共用文件锁，避免并发覆盖文件和备份。
- 下载或校验失败时保留原文件，不切换到其他源。
- 替换前保留上一版本；V2bX 重启失败时自动回滚。
- 文件发生变化后才重启 `V2bX.service`。
- 重启后连续检查 3 秒的运行状态；服务原本未运行时不主动启动。
- 手动更新、首次安装检查和定时更新均保存执行时间、结果与最近成功时间。首次检查失败仍会安装定时任务，但命令返回失败并明确提示。

## 管理命令

安装完成后，直接运行 `v2bx-geo` 即可打开中文管理菜单：

```text
0. 立即更新 Geo 文件
1. 查看自动更新状态
2. 查看更新日志
3. 重载自动更新任务
4. 查看 Geo 文件信息
5. 卸载自动更新任务
6. 查看脚本版本
7. 退出脚本
8. 更新管理脚本版本
```

也可以直接使用命令：

```bash
v2bx-geo status      # 查看自动更新状态
v2bx-geo update      # 立即手动更新
v2bx-geo log         # 查看更新日志
v2bx-geo version     # 查看脚本版本
v2bx-geo self-update # 从本仓库 main 分支更新管理和定时更新脚本
v2bx-geo uninstall   # 卸载自动更新任务
```

`self-update` 会检查下载内容的脚本标识、版本格式和 Bash 语法，拒绝降级；两个已安装脚本均暂存后才替换，普通替换失败时恢复旧版本。它不下载 Geo 数据、不重启 V2bX，也不会自动在每天的 Geo 更新中执行。远程脚本来自本仓库 HTTPS 地址，这些检查不能代替发布者签名。

旧版本没有 `self-update` 命令，需要先重新运行安装脚本升级一次。仓库未发布本地改动前，一键安装仍获取旧版。

## 状态与北京时间

`v2bx-geo status` 优先读取持久执行记录；旧安装则尝试读取 timer 的 `LastTriggerUSec` 和服务的启动时间。旧版直接执行的手动更新没有历史时间可恢复，需要在升级后执行一次 `v2bx-geo update` 建立记录。

例如 `Fri 2026-10-16 20:00:00 UTC` 会显示为 `2026-10-17 04:00:00 北京时间`。状态中的“最近成功”包括文件无变化的成功检查，不等同于最近一次替换文件的时间。

## 文件位置

```text
/etc/V2bX/geoip.dat
/etc/V2bX/geosite.dat
/etc/systemd/system/v2bx-geo-update.timer
/var/backups/V2bX-geo/
/var/lib/v2bx-geo/status
/var/lib/v2bx-geo/update.log
```

日志达到 1 MiB 后在下次任务开始时轮换，保留当前与上一份日志。卸载保留 Geo 文件、备份和历史记录。

## 恢复与验证范围

回滚通过临时文件写入后重命名恢复。收到 TERM、INT、HUP 或普通提交失败时，脚本尝试恢复原文件。回滚失败时保留临时恢复现场，并暂停后续 Geo 更新以保护备份。

断电或 `SIGKILL` 无法执行退出处理，也不能保证两个文件同时恢复。下次执行发现遗留的“执行中”记录会暂停更新。请先查看日志中的恢复现场与备份，确认两个 Geo 文件和 V2bX 运行正常；完成手动恢复后，才删除 `/var/lib/v2bx-geo/status` 解除暂停并重新检查。不要删除锁文件。

更新只接受普通 Geo 文件，目标为目录或符号链接时会拒绝操作。SHA-256 验证下载文件与上游发布一致，不替代 Xray 的格式解析。服务运行状态检查也不等同于实际代理请求成功。

## 开发验证

在 Linux 或 WSL 中运行（Python 3.9+）：

```bash
bash -n install.sh
shellcheck -x -P SCRIPTDIR install.sh tests/smoke_upstream.sh
sudo python3 -m unittest discover -s tests -v
```

测试使用临时目录和模拟命令，不修改真实服务或安装路径。以 root 运行可覆盖会启动子脚本的安装用例；普通用户运行会跳过这两项。生成的 unit 文件由 `systemd-analyze verify` 检查。

可选的真实上游下载验证（仅下载到临时目录并校验，不安装任务、不修改现有 Geo 数据）：

```bash
bash tests/smoke_upstream.sh
```
