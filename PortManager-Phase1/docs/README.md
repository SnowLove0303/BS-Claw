# BSClaw 慧策通端口管理（第一阶段）

## 一、功能定义

本项目是在 BSClaw 主系统之外运行的独立 PowerShell 端口管理程序。它通过资源编号管理真实主机地址、真实端口、浏览器启动配置和最近检测状态，并能连接已有 Chromium 调试端口，或按登记配置启动浏览器后进行真实回查。

本模块与 `HuiceLoginAgent` 作为同一 BS-Claw 仓库交付，但尚未接入 Electron UI、完整插件加载器或统一调度器。PortManager SQLite 是资源、租约、审计和当前状态真源。

## 二、功能意义

业务脚本和未来插件只引用 `HCP-XXXXXXXX` 格式的资源编号，不直接写死端口号。端口、浏览器程序、F 盘浏览器配置目录、页面规则和状态检测集中保存，便于未来由 BSClaw 统一接管资源、任务、确认和审计。

## 三、功能作用

当前支持：

1. 注册真实端口并检查格式、重复、监听进程和连接状态。
2. 查看列表与详情。
3. 编辑、启用和停用未被使用的资源。
4. 删除无租约、无运行任务且无活动监听进程的资源。
5. 分层检测 TCP、HTTP、Chromium 调试接口、慧策页面和登录证据。
6. 按资源编号连接或启动指定浏览器，并打开登记的慧策页面。
7. 将真实配置、状态、审计和脱敏日志持久化到独立 F 盘目录。
8. 预览或安全清理可再生浏览器缓存，并创建不影响正式会话的独立登录测试环境。
9. 通过唯一根入口提供占用、租约、异步登录检测、慧策登录适配和全模块体积盘点。

## 四、快速开始

从任意 Windows PowerShell 工作目录运行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1"
```

普通用户首次注册只需要：

1. 输入 `1`。
2. 若程序发现已打开且可识别的慧策通 Chrome，选择使用它；否则直接回车采用“自动启动新的 Chrome”。
3. 资源名称可以直接回车，程序默认生成 `慧策通端口-端口号`。
4. 注册完成后查看自动检查结果，再选择“立即打开慧策通”“再次检查”或“返回菜单”。

端口、Chrome 程序、F 盘配置目录、慧策页面和识别规则均由程序自动处理。只有自动检测失败或明确需要自定义时才进入“高级设置”。

主菜单：

```text
1. 注册慧策通端口
2. 查看端口列表
3. 查看端口详情
4. 编辑端口
5. 删除端口
6. 检测端口状态
7. 打开指定慧策通端口
8. 检查全部端口
9. 清理端口环境
0. 退出程序
```

常用命令：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action List
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Register
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Detail -ResourceId HCP-XXXXXXXX
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Check -ResourceId HCP-XXXXXXXX
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId HCP-XXXXXXXX
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action CheckAll
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action StorageAudit -OutputFormat Json -NonInteractive
```

清理与登录重测命令均使用绝对路径，不依赖当前工作目录：

```powershell
# 只预览，不删除
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action CachePlan -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive

# 只清理可再生缓存，不用于退出登录；必须先关闭对应 Chrome
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action CleanCache -ResourceId HCP-XXXXXXXX -ConfirmationText "确认清理可再生缓存 HCP-XXXXXXXX" -OutputFormat Json -NonInteractive

# 创建独立端口和空白 Profile，用于重新测试完整 Login
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action CreateLoginTestProfile -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive

# 只输出跨机器部署前的保留、可清理和重建建议
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action DeploymentCleanPlan -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
```

`CreateLoginTestProfile` 不复制密码、Token、Cookie 或浏览器会话。`ResetLoginPlan` 只输出风险说明；本阶段不删除正式资源认证状态。

未来适配层可使用中文消息的 JSON 信封：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Edit -ResourceId HCP-XXXXXXXX -ResourceName '新名称' -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Delete -ResourceId HCP-XXXXXXXX -ConfirmationText '删除 HCP-XXXXXXXX' -OutputFormat Json -NonInteractive
```

`Json` 模式的标准输出严格只有一个 JSON 文档；不会输出提示、详情表格或确认文本。失败时仍返回相同信封，进程退出码为非零。机器编辑必须提供至少一个修改参数，机器删除必须提供确认文本。

## 五、连接方式

### ConnectOnly

只连接已经监听的真实端口，不启动浏览器。端口不是 Chromium 调试接口时会报告端口冲突或浏览器未连接。

主机范围只允许 `localhost`、明确的回环 IP、RFC1918 私网 IP、链路本地 IP 或 IPv6 ULA；不接受远程 DNS 主机名或公网 IP。远程私网资源仅允许 TCP/HTTP/CDP 状态读取，第一阶段 `Open` 只允许回环地址，绝不会对远程主机调用 `/json/new` 或 `/json/activate`。

### Launch

端口未监听时，使用登记的浏览器程序、端口和 F 盘浏览器配置目录启动浏览器。Chrome 136 及更高版本要求 `--remote-debugging-port` 配合非默认 `--user-data-dir`，因此本程序拒绝把自建配置目录放到 C 盘。

浏览器程序本身可以安装在 C 盘；程序只读取可执行文件。浏览器产生的新配置和运行数据必须写入登记的 F 盘目录。

## 六、状态解释

- `不可连接`：TCP 连接失败或超时。
- `端口已监听`：TCP 可连接，但还不能证明它是浏览器。
- `浏览器可连接`：`/json/version` 返回可识别的 Chromium 调试信息。
- `端口冲突`：端口有监听进程，但不是可识别的调试接口。
- `平台页面正确`：`/json/list` 中存在匹配登记规则的真实页面。
- `未登录`：发现用户明确登记的登录页规则。
- `登录状态未知`：没有独立鉴权证据。端口、浏览器或页面正确都不会自动标记为已登录。
- `检测失败` / `打开失败`：执行异常已写入最新状态；List 和 Detail 会显示本次错误，而不是旧状态。
- `当前占用`：同时汇总活动监听进程和未过期操作租约；租约结束后会恢复实时占用视图。

PortManager 本身不持久化 Cookie、Token、密码或完整授权头。慧策登录适配器通过当前 Chrome/CDP 页面在内存中取得实时鉴权材料，并以鉴权续接和只读 API 探针作为登录证据；成功时可写入“已登录 / high / logged-in-api-ready”。插件不得自行读取旧会话表或浏览器秘密，只能读取 `port_runtime_states`，并在执行前按需 Check。

## 七、数据与回滚

无论从哪个当前目录启动，正常运行数据都固定在项目的 F 盘 `data` 目录：

- SQLite 唯一运行时真源：`data\port-manager.sqlite3`
- JSON 仅作首次迁移输入/人工备份：`data\ports.json`、`data\migrations\legacy`
- 操作审计：SQLite `audit_records`（兼容导出：`data\audit.jsonl`）
- 短期操作租约：SQLite `resource_leases`
- 脱敏日志：`logs\port-manager.log`
- 自动创建的 Chrome 配置：`F:\BS-Claw\_portmanager-profiles`

当前阶段端口资源、状态、租约、审计和测试记录统一写入 `F:\BS-Claw\PortManager-Phase1\data`；自动回归通过进程级环境变量 `BSCLAW_PM_RUNTIME_ROOT` 指向 `data\test-runs` 下的 F 盘隔离目录，该变量只影响当前进程及其子进程。

备份与恢复 SQLite：

```powershell
Import-Module '.\scripts\lib\PortManager.Sqlite.psm1' -Force
Initialize-PMSqlite -DataRoot '.\data' -JsonPath '.\data\ports.json'
Backup-PMSqliteDatabase -Destination '.\data\migrations\port-manager-backup.sqlite3'
Test-PMSqliteIntegrity
```

恢复前关闭程序，保留当前 SQLite 文件和备份；恢复动作应在隔离副本上执行并先通过 `Test-PMSqliteIntegrity`，旧 JSON 不能作为运行时恢复源。

## 八、公开方案依据

- Chrome 远程调试安全变更：<https://developer.chrome.com/blog/remote-debugging-port>
- Chrome DevTools Protocol HTTP 端点：<https://chromedevtools.github.io/devtools-protocol/>
- GoogleChrome `chrome-launcher` 公开实现：<https://github.com/GoogleChrome/chrome-launcher>
- PowerShell `Get-NetTCPConnection`：<https://learn.microsoft.com/powershell/module/nettcpip/get-nettcpconnection>
- PowerShell `Start-Process`：<https://learn.microsoft.com/powershell/module/microsoft.powershell.management/start-process>

## 九、当前完成边界

代码已实现独立执行路径、统一根入口、真实状态复用和推广前体积审计。历史本机资源验证不作为仓库发布事实。迁入后的完整冷启动 Login 必须由用户在独立登录测试资源按仓库根目录 `docs/manual-validation.md` 复验；自动化只覆盖不需要真实凭据的部分，不得将未执行场景描述为通过。
## 十、SQLite 运行时真源（2026-07-28）

端口配置、运行状态、登录检测历史、资源租约和可查询审计记录的唯一运行时真源是：

`F:\BS-Claw\PortManager-Phase1\data\port-manager.sqlite3`

SQLite 由 `scripts\sqlite_service.py`（Python 标准库 sqlite3）提供统一访问，PowerShell 模块 `scripts\lib\PortManager.Sqlite.psm1` 是唯一调用入口。数据库启用外键、WAL 和 10 秒 busy timeout；写入通过事务完成。核心表为 `schema_migrations`、`port_resources`、`port_runtime_states`、`login_state_checks`、`login_detection_tasks`、`resource_leases`、`audit_records`、`deleted_resource_history`、`credential_profiles` 与 `login_session_events`，当前 schema migration 为 36，启动会校验 migration checksum。

旧 `data\ports.json`、`leases.json`、`login-detections.json` 只用于首次迁移、备份或人工导出，不再作为运行时读写源，也不会被删除。首次初始化会在 `data\migrations` 写入 `pre-sqlite-baseline.json` 及 legacy 副本；迁移失败会回滚 SQLite 事务并保留 JSON 回滚基线。

SQLite 中只保存端口复用所需的安全元数据。Cookie 值、Token、密码、完整授权头、浏览器 Profile 和缓存不会进入数据库、日志或审计记录。`port_runtime_states` 是当前状态真源；`login_session_events` 是追加式证据；旧 `login_sessions` 仅为从真源单向更新的兼容投影。
