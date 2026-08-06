# HuiceLoginAgent

慧策登录、状态检测与 PortManager 状态同步适配器。PortManager 是资源、租约和当前状态真源；本适配器负责复用真实会话、执行受控同源 HTTP 登录、进入 ERP，并通过鉴权刷新和只读 API 探针提供证据。

两个模块在仓库中保持同级。默认自动发现相邻 `PortManager-Phase1`；非同级部署时使用进程环境变量 `BSCLAW_PORT_MANAGER_ROOT` 指向 F 盘 PortManager 根目录。

```powershell
$RepoRoot = "F:\BS-Claw"
$ResourceId = "<隔离测试资源编号>"
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId
```

`Login` 先实时检查并复用已存在的 ERP 会话或产品选择页。只有真实未登录时才在 PowerShell 读取企业/卖家账号、操作员/用户账号、不回显密码和明确的服务协议确认。凭据只存在于受控内存；数据库不保存密码、Token、Cookie 或完整授权头。发布实现只保留同源 HTTP 登录主链，不包含 Chrome 表单填写或点击的竞争实现。

登录成功后，程序进入旺店通 ERP3.0，执行鉴权续接与 goods overview 只读探针；二者都成功才返回 `logged-in-api-ready`。验证码、短信、滑块、二维码或二次确认不能自动完成时必须返回明确阻断，不得伪装成功。

正式集成由 PortManager 根据 ResourceId/CredentialRef 提供一次性内存凭据。插件、调度器、MCP 和其他 UI 模块只传 ResourceId，不能接触明文凭据。完整人工验收见仓库根目录 `docs/manual-validation.md`。
