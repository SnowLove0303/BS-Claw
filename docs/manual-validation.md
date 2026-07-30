# 端口管理与慧策登录人工验证

## 解决的问题

验证端口管理能保存和复用慧策资源，且真实未登录时可在 PowerShell 安全输入账号信息，通过同一 Chrome、端口和 Profile 完成登录，最终得到 ERP/API 可用状态。

## 一、克隆发布分支

准备一个新的 F 盘目录；不要覆盖现有正式资源目录：

```powershell
git clone --branch agent/portmanager-login-agent-migration --single-branch https://github.com/SnowLove0303/BS-Claw.git "F:\BS-Claw"
$RepoRoot = "F:\BS-Claw"
```

预期：`PortManager-Phase1` 与 `HuiceLoginAgent` 是同级目录；仓库内没有 SQLite、真实资源、Profile、账号或缓存。

## 二、准备运行环境

1. Windows PowerShell 5.1 或更高版本。
2. F 盘已有带标准库 `sqlite3` 的 Python，或把该 Python 放在 `PortManager-Phase1\tools\python\python.exe`。
3. 已安装 Google Chrome。
4. 使用隔离测试资源验证 Login；不要清除或重置正在使用的正式资源。

```powershell
$env:BSCLAW_PYTHON_PATH = "F:\<你的 Python 目录>\python.exe"
```

如果未设置且项目内也没有 Python，测试入口只输出一条“BS-Claw 测试与诊断需要 F 盘 Python（含 sqlite3）”提示并以退出码 2 结束；不会下载依赖、修改用户/系统环境变量或创建数据库与测试目录。按上面的当前会话命令设置后重新执行即可。

## 三、最短验证流程

### 1. 查看空库或现有资源

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
```

预期：返回单一 JSON；新环境为成功且资源列表为空，已有环境列出已登记资源。

### 2. 注册隔离测试资源

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Register
```

按中文向导选择“自动启动新的 Chrome”。注册完成后记录屏幕显示的 `HCP-XXXXXXXX` 资源编号：

```powershell
$ResourceId = "HCP-XXXXXXXX"
```

预期：创建独立 F 盘 Profile，返回真实资源编号、端口和检测结果；不会生成虚构资源或复制其他已登录 Profile。

### 3. 检查并打开指定资源

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Check -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId $ResourceId -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
```

预期：两条命令均返回单一 JSON；Open 使用登记端口与 Profile，不创建另一套未登记 Profile。

### 4. 检查登录状态

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action HuiceCheck -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

已登录时预期：`loginStatus=已登录`、`loginApiProbeStatus=logged-in-api-ready`、`loginConfidence=high`。未登录时必须明确返回需要登录，不能沿用旧成功状态。

### 5. 真实未登录时执行交互式 Login

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId
```

按提示依次输入企业/卖家账号、操作员/用户账号、不回显密码，并明确输入“同意”确认页面服务协议。不要在 Chrome 中再次输入或点击登录。

预期：程序通过同一浏览器会话执行同源 HTTP 登录，进入 ERP，鉴权刷新与只读探针成功，最终返回 `success=true` 和 `logged-in-api-ready`。

若出现图片验证码、短信、滑块、二维码或二次确认，只在同一登记 Chrome 中完成该项外部安全验证；不要在 Chrome 重输账号/密码、点击普通登录表单或复制 Token/Cookie。完成后重新执行同一条交互式 Login，程序会继续走同源 HTTP 主链。

### 6. 验证状态、租约与无凭据复用

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Detail -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

预期：Detail 为已登录/high/API-ready；Occupancy 的活动租约为 0；第二次 Login 不再询问凭据，并复用同一 ResourceId、端口、Profile 和 Chrome PID。

## 四、通过与失败标准

通过：登录进入 ERP、refresh/probe 成功、状态落库、租约归零、第二次无凭据复用且未生成新 Profile。

失败：仍停留登录页、出现安全验证错误、API 探针失败、Detail 未同步、活动租约残留、端口/Profile/PID 被替换，或输出混入凭据。

反馈失败时只提供：执行时间、资源编号、非敏感 JSON 错误码与 message、页面主机名、PortManager Detail/Occupancy 输出。不要提供账号、密码、Token、Cookie 或完整授权头。

如果 Python 前置检查失败，先确认 `$env:BSCLAW_PYTHON_PATH` 指向 F 盘 `python.exe`，并执行：

```powershell
& $env:BSCLAW_PYTHON_PATH -c "import sqlite3; print(sqlite3.sqlite_version)"
```

如果登录遇到外部安全验证，只在同一登记 Chrome 完成该项验证，然后重新运行第 5 步；不要在 Chrome 重输账号密码，也不要复制 Token/Cookie。

## 五、本轮人工验证边界

当前验收基线（2026-07-30）：最终 Read-Host 用户路径已在隔离资源完成冷启动登录并进入 ERP；refresh/probe 均为 HTTP 200，Detail 为已登录/high/API-ready，活动租约为 0，第二次 NonInteractive 调用复用同一端口、Profile 和 Chrome PID。外部验证码/风控是否出现取决于慧策实时策略，出现时按上述人工续接步骤处理。

发布分支每次代码整改不会代替用户重新输入真实账号密码。本次用户人工验收应从第 1 步开始；只有第 5、6 步实际进入 ERP、API-ready、租约归零并复用原端口/Profile/PID，才算完整登录通过。
