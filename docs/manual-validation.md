# 端口管理与慧策登录人工验证

## 解决的问题

验证端口管理能保存和复用慧策资源，且真实未登录时可在 PowerShell 安全输入账号信息，通过同一 Chrome、端口和 Profile 完成登录，最终得到 ERP/API 可用状态。

## 前置条件

1. Windows PowerShell 5.1 或更高版本。
2. 仓库位于 F 盘，例如 `F:\BS-Claw`。
3. F 盘已有带标准库 `sqlite3` 的 Python，并通过 `BSCLAW_PYTHON_PATH` 指定，或放在 `PortManager-Phase1\tools\python\python.exe`。
4. 已安装 Google Chrome。
5. 已通过 PortManager 注册一个专用于登录测试的慧策资源。不要清除或重置正在使用的正式资源。
6. 外部验证码、短信、滑块、二维码或二次确认可能阻断自动登录；这类情况必须按返回错误码处理，不能判定为通过。

先设置本机仓库绝对路径：

```powershell
$RepoRoot = "F:\BS-Claw"
$env:BSCLAW_PYTHON_PATH = "F:\<你的 Python 目录>\python.exe"
```

如果未设置且项目内也没有 Python，测试入口只输出一条“BS-Claw 测试与诊断需要 F 盘 Python（含 sqlite3）”提示并以退出码 2 结束；不会下载依赖、修改用户/系统环境变量或创建数据库与测试目录。按上面的当前会话命令设置后重新执行即可。

## 最短验证流程

### 1. 查看空库或现有资源

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
```

预期：返回单一 JSON；新环境为成功且资源列表为空，已有环境列出已登记资源。

### 2. 打开或复用指定资源

```powershell
$ResourceId = "<隔离测试资源编号>"
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId $ResourceId -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
```

预期：复用登记端口与 Profile；不得创建另一套未登记 Profile。

### 3. 检查登录状态

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action HuiceCheck -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

已登录时预期：`loginStatus=已登录`、`loginApiProbeStatus=logged-in-api-ready`、`loginConfidence=high`。未登录时必须明确返回需要登录，不能沿用旧成功状态。

### 4. 真实未登录时执行交互式 Login

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId
```

按提示依次输入企业/卖家账号、操作员/用户账号、不回显密码，并明确输入“同意”确认页面服务协议。不要在 Chrome 中再次输入或点击登录。

预期：程序通过同一浏览器会话执行同源 HTTP 登录，进入 ERP，鉴权刷新与只读探针成功，最终返回 `success=true` 和 `logged-in-api-ready`。

若出现图片验证码、短信、滑块、二维码或二次确认，只在同一登记 Chrome 中完成该项外部安全验证；不要在 Chrome 重输账号/密码、点击普通登录表单或复制 Token/Cookie。完成后重新执行同一条交互式 Login，程序会继续走同源 HTTP 主链。

### 5. 验证状态、租约与无凭据复用

```powershell
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Detail -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

预期：Detail 为已登录/high/API-ready；Occupancy 的活动租约为 0；第二次 Login 不再询问凭据，并复用同一 ResourceId、端口、Profile 和 Chrome PID。

## 通过与失败标准

通过：登录进入 ERP、refresh/probe 成功、状态落库、租约归零、第二次无凭据复用且未生成新 Profile。

失败：仍停留登录页、出现安全验证错误、API 探针失败、Detail 未同步、活动租约残留、端口/Profile/PID 被替换，或输出混入凭据。

反馈失败时只提供：执行时间、资源编号、非敏感 JSON 错误码与 message、页面主机名、PortManager Detail/Occupancy 输出。不要提供账号、密码、Token、Cookie 或完整授权头。

当前验收基线（2026-07-30）：最终 Read-Host 用户路径已在隔离资源完成冷启动登录并进入 ERP；refresh/probe 均为 HTTP 200，Detail 为已登录/high/API-ready，活动租约为 0，第二次 NonInteractive 调用复用同一端口、Profile 和 Chrome PID。外部验证码/风控是否出现取决于慧策实时策略，出现时按上述人工续接步骤处理。
