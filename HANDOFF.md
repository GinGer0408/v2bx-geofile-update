# V2bX Geo 项目开发交接

交接日期：2026-10-16（北京时间，UTC+8）。

## 1. 新机器上的接手入口

- 仓库：<https://github.com/GinGer0408/v2bx-geofile-update>
- 开发分支：`main`
- 当前脚本版本：`1.3.0`
- 已发布的功能代码基线：`e10209b92e5c5dd9e13c2896997b05294406d502`
- 代码提交说明：`Fix update history and Beijing time; add safe script self-update`
- 已通过的基线 CI：<https://github.com/GinGer0408/v2bx-geofile-update/actions/runs/38886604641>
- 旧机器工作目录：`C:\V2bx-geo`。仓库实际名称为 `v2bx-geofile-update`，不是 `v2bx-geo`；后者是安装后的管理命令。

交接文档作为独立提交添加在上述功能提交之后，所以新机器的 HEAD 可以晚于该基线。接手时重新检查远端与 CI，不要把本文中的快照当成未来的实时状态。

新机器为 Windows 时，可以在 PowerShell 中克隆到一个尚不存在的目录：

```powershell
git clone https://github.com/GinGer0408/v2bx-geofile-update.git C:\V2bx-geo
Set-Location C:\V2bx-geo
git status --short
git log -3 --oneline
git merge-base --is-ancestor e10209b92e5c5dd9e13c2896997b05294406d502 HEAD
```

预期 `git status --short` 无输出，最后一条命令退出码为 0。若目录已经存在，先检查其中内容和 Git 状态，不要覆盖或重置。

新机器需要自行配置 Git 提交身份与 GitHub 登录。不要复制旧机器的令牌、凭据缓存或 SSH 私钥到仓库。本项目没有迁移所必需的本地构建产物或未跟踪业务文件。

## 2. 项目用途与边界

项目是单文件 Bash 管理脚本，为标准 V2bX 的 Xray Geo 数据提供自动更新：

- 管理 `/etc/V2bX/geoip.dat` 与 `/etc/V2bX/geosite.dat`。
- 使用 `Loyalsoldier/v2ray-rules-dat` 的发布文件；不自动切换下载源。
- 仅支持运行中的 systemd，标准服务名为 `V2bX.service`；不支持 Alpine/OpenRC。
- 不修改 V2bX 核心程序，不把该项目扩展为 V2bX 核心二次开发。
- 运行安装、更新、卸载等管理命令需要 root。
- 每天北京时间 04:00 检查 Geo 更新；不改变 VPS 的系统时区。

开发机器与部署 VPS 是两件事。克隆仓库、运行隔离测试不会把脚本安装到 VPS；不要在开发机直接运行不带参数的 `bash install.sh` 来代替测试。

## 3. 用户需求和已完成的修改

用户原先反馈状态页长期显示“上次执行：暂无记录”，下次执行显示 UTC；同时要求增加脚本版本更新功能并全面检查项目。

| 项目 | 已实现的行为 |
| --- | --- |
| 执行历史 | 保存所有正常进入更新流程的安装首次检查、手动更新、定时更新记录，包括执行时间、结果和最近成功时间 |
| 旧版状态兼容 | 优先读持久状态；没有记录时尝试 timer 的 `LastTriggerUSec`，再尝试 service 的 `ExecMainStartTimestamp` |
| 北京时间显示 | 通过进程内 `TZ=CST-8` 统一状态、日志、文件时间显示；timer 使用 `Asia/Shanghai` |
| 脚本自更新 | `v2bx-geo self-update` 或菜单 8，从本仓库 `main/install.sh` 下载新版 |
| 自更新检查 | 静态检查脚本标识、版本格式和 Bash 语法，拒绝降级；替换两个已安装脚本失败时尝试恢复旧版 |
| 数据完整性 | Geo 数据与上游 `.sha256sum` 对比 SHA-256，任一下载或校验失败均中止 |
| 发布一致性 | 先解析一次最新发布，再从同一个发布版本下载两个数据文件及校验文件 |
| 并发控制 | 更新、自更新、安装、卸载、重载任务使用同一个持久锁文件 |
| 数据替换与回滚 | 两个数据文件均通过校验后才提交；普通失败及 TERM/INT/HUP 会尝试恢复 |
| 服务重启 | 文件有变化且服务原本运行时才重启，之后观察 3 秒运行状态；原本停止则不主动启动 |
| 恢复保护 | 上次状态为 `running` 或 `recovery_failed` 时暂停后续 Geo 更新，避免覆盖恢复备份 |
| 日志 | 保存手动与自动任务日志，达到 1 MiB 后在下一次任务开始时轮换，保留当前与上一份 |
| 安装失败提示 | 首次 Geo 检查失败仍保留定时任务，但明确提示并返回非零退出码 |
| 文件目标检查 | Geo 目标为目录或符号链接时拒绝更新 |
| 卸载 | 保留 Geo、备份和执行历史；V2bX 配置目录已被移除时仍可卸载管理任务 |
| Windows 换行 | `.gitattributes` 强制 `.sh`、`.py`、`.yml` 使用 LF，避免 Bash 的 CRLF 语法错误 |

原问题的具体根因：旧代码读取了不存在的 `LastTriggerUSecRealtime`；正确属性为 `LastTriggerUSec`。安装首次检查和菜单更新直接运行脚本，本来也不属于 timer 的触发历史。

用户贴出的 `Fri 2026-10-16 20:00:00 UTC` 对应 `2026-10-17 04:00:00 北京时间`，原调度时间本身没有偏移。旧版没有保存过的手动执行时间不能凭空恢复，升级后需完成一次更新检查建立新记录。“最近成功”包含文件无变化的成功检查，不是最近一次文件替换时间。

## 4. 文件与函数索引

| 文件 | 用途 |
| --- | --- |
| `install.sh` | 安装、中文菜单、Geo 更新、状态、日志、自更新、卸载；当前全部实现位于此文件 |
| `README.md` | 面向用户的安装、命令、恢复和测试说明 |
| `tests/test_updater.py` | Python unittest，使用临时目录和模拟外部命令测试实际 Bash 函数 |
| `tests/smoke_upstream.sh` | 可选的真实上游下载与校验，不安装任务、不接触正在使用的 Geo 文件 |
| `.github/workflows/ci.yml` | Bash 语法、ShellCheck、帮助与版本命令、隔离回归测试 |
| `.gitattributes` | 跨平台换行规则 |
| `.gitignore` | 忽略 Python 缓存 |

主要函数：

- `format_time`、`show_status`、`show_geo_info`：北京时间显示与状态查询。
- `acquire_lock`：在状态目录中的 `.lock` 上使用 `flock`；锁文件不可删除。
- `load_state`、`save_state`、`prepare_state`：读取状态、临时文件重命名保存状态、日志轮换。
- `resolve_release`、`download_and_validate`：固定上游版本并校验文件。
- `update_geo`：更新事务；退出处理负责恢复和保存最终状态。
- `restart_v2bx`：重启并短暂观察服务存活。
- `install_script_pair`：暂存并替换两个已安装脚本，失败时尝试恢复。
- `self_update`：下载和检查新脚本后调用脚本替换流程。
- `install_geo`、`uninstall_geo`、`reload_timer`：安装、卸载与任务重载。

`install.sh` 被 `source` 时只定义函数，不进入安装入口，供测试与 smoke 脚本使用。修改时保持该行为，并注意 Bash 函数在 `if`、`||` 等上下文中可能忽略 `set -e`，关键操作应显式检查返回值。

## 5. 运行路径与持久数据

| 内容 | 默认路径 |
| --- | --- |
| Geo 数据 | `/etc/V2bX/geoip.dat`、`/etc/V2bX/geosite.dat` |
| 定时更新脚本 | `/usr/local/sbin/v2bx-update-geo` |
| 管理脚本 | `/usr/local/bin/v2bx-geo` |
| service | `/etc/systemd/system/v2bx-geo-update.service` |
| timer | `/etc/systemd/system/v2bx-geo-update.timer` |
| 上一版本数据备份 | `/var/backups/V2bX-geo/geoip.dat.previous`、`geosite.dat.previous` |
| 持久状态 | `/var/lib/v2bx-geo/status` |
| 日志 | `/var/lib/v2bx-geo/update.log`、`update.log.1` |
| 持久锁文件 | `/var/lib/v2bx-geo/.lock` |

状态文件是制表符分隔的键值行：`attempt`、`success` 为 Unix 秒时间戳，`result` 为结果标识；读取时不执行文件内容。结果包括 `running`、`updated`、`unchanged`、`failed`、`recovery_failed`。

代码提供的环境变量覆盖包括 `V2BX_DIR`、`V2BX_SERVICE`、`V2BX_GEO_UPDATER`、`V2BX_GEO_MANAGER`、`V2BX_GEO_BACKUP_DIR`、`V2BX_GEO_STATE_DIR`、`V2BX_GEO_UNIT_DIR`，测试通过它们隔离路径。安装生成的 service 会保存相关配置；若手动使用非默认配置，后续手动命令也应提供一致的环境，不能假定新登录会话自动保留它们。

## 6. 新机器验证方法

建议使用 Linux 或 Windows 的 WSL；单独的 PowerShell、Git Bash 不能替代完整测试环境。需要 Python 3.9+、Bash、ShellCheck、systemd-analyze，以及标准 Linux 工具。实际安装另需运行中的 systemd 和 `tzdata` 的 `Asia/Shanghai` 数据。

Windows 按第 1 节克隆后，在 WSL 中运行：

```bash
cd /mnt/c/V2bx-geo
bash -n install.sh
shellcheck -x -P SCRIPTDIR install.sh tests/smoke_upstream.sh
bash install.sh --help
bash install.sh version
sudo python3 -m unittest discover -s tests -v
```

Linux 原生克隆时换成自己的仓库目录。Ubuntu/Debian 可按实际缺失情况安装 `python3 shellcheck systemd curl ca-certificates coreutils util-linux tzdata`。不需要安装 Go、Node.js 或 Python 第三方包。

预期：版本显示 `1.3.0`，35 项测试通过，ShellCheck 无告警。以普通用户运行会跳过两项需要启动 root 子脚本的安装测试；完整验证应运行上面的 sudo 命令。测试里的外部服务操作被模拟，unit 文件仅写临时目录，再通过 `systemd-analyze verify` 检查。

可选的网络验证：

```bash
bash tests/smoke_upstream.sh
```

此命令会真实下载 Geo 数据及校验文件到临时目录，完成后清理，不操作 V2bX 服务。上次开发验证使用上游发布 `202610152206`，`geoip.dat` 为 16587393 字节，`geosite.dat` 为 11197777 字节，SHA-256 均通过。这些大小和发布号只是当时的证据，不应硬编码为未来测试预期。

## 7. 发布与 VPS 验收状态

功能代码已推送到 GitHub `main`，上述基线 CI 已确认成功。本次交接文档不改变脚本版本。

此前直接推送时，GitHub 提示通过管理员权限绕过了尚未产生的 `Verify` 必需检查，随后该提交的 CI 实际通过。没有修改分支保护设置；后续发布应查看当时权限和检查要求，不要为了推送去关闭保护。

尚未连接用户的实际 VPS 部署或验证新版，也没有用户升级后的状态输出。不能把本地隔离测试、真实文件下载或 CI 成功描述为实际 VPS 已验收。

如果用户仍运行旧版，需要重新运行安装脚本升级一次；旧版没有 `self-update` 命令：

```bash
curl -fL https://raw.githubusercontent.com/GinGer0408/v2bx-geofile-update/main/install.sh -o /tmp/v2bx-geo-install.sh &&
bash /tmp/v2bx-geo-install.sh
v2bx-geo version
v2bx-geo status
v2bx-geo log
```

该部署命令需要 root，会安装或更新管理任务，并立即检查 Geo；数据变化时可能重启正在运行的 V2bX。它属于用户目标 VPS 上的部署步骤，不是新开发机的初始化命令。

升级完成后的常用命令：

```bash
v2bx-geo update       # 检查并更新 Geo 数据
v2bx-geo self-update  # 更新管理脚本，不更新 Geo、不重启 V2bX
```

建议下一步先收集用户 VPS 的 `version`、`status`、`log` 输出，确认时间、历史记录、自更新与定时任务工作正常，再依据实际新需求继续开发。当前没有另行承诺但尚未完成的新功能。

## 8. 已知限制与接手注意事项

1. 两个 Geo 文件分别重命名提交，并不是一项跨文件原子操作。普通失败和可捕获信号已有恢复测试；断电、`SIGKILL` 或磁盘故障不能保证自动恢复。
2. 发现遗留 `running` 或 `recovery_failed` 记录会暂停后续更新。先查看日志、临时恢复现场和备份，手动确认两个 Geo 文件及 V2bX 正常，之后才可删除状态文件解除暂停；不要直接删状态掩盖未解决的故障，也不要删除锁文件。
3. SHA-256 证明数据匹配上游校验值，不等于验证 Xray 二进制格式或证明上游发布可信。
4. 脚本自更新依赖本仓库 HTTPS 内容，没有独立发布者签名。标识、版本和语法检查不是签名验证；版本不变时不会安装同版本的代码修订，因此发布脚本改动应同步递增版本并更新文档、测试中的版本假设。
5. 自更新只替换两个脚本，不重新生成 systemd unit。未来若修改 unit 模板或增加系统依赖，应提供明确迁移流程，不能假设旧安装运行一次 `self-update` 就完成迁移。
6. 3 秒的服务状态观察只能发现部分早期退出，不证明服务长期稳定，也不代表端到端代理请求成功。
7. 卸载按设计保留 Geo、备份和历史；这些数据不在 Git 仓库中。若将运行中的 VPS 也迁移到新服务器，应另行规划运行数据迁移，不能只克隆仓库。
8. 尽量保持中文菜单、清晰错误提示和现有源选择。用户要求修复实际缺陷，不能把仅新增 CI 或测试当成已修复业务问题。

## 9. 可粘贴给下一位开发助手的上下文

> 请先阅读仓库根目录的 HANDOFF.md、README.md、install.sh 和 tests。项目为 GinGer0408/v2bx-geofile-update，当前版本 1.3.0，功能基线 e10209b92e5c5dd9e13c2896997b05294406d502 已推送且 CI 通过。已实现北京时间显示、持久状态与日志、脚本自更新、校验和并发及恢复保护。请先检查当前 Git 状态和远端，不覆盖用户改动；用 Linux/WSL 运行隔离测试，不在开发机直接安装服务。实际用户 VPS 的新版部署尚未验收。继续根据用户的新指令开发，不要重复宣称已经完成线上验证。
