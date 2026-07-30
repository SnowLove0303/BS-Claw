# HuiceLoginAgent 人工测试

最终主验收以仓库根目录 `docs/manual-validation.md` 为准。必须使用 PowerShell `Read-Host` 真实交互路径；重定向标准输入仅用于传输兼容性诊断，不能替代用户路径。

```powershell
$RepoRoot = "F:\BS-Claw"
$ResourceId = "<隔离测试资源编号>"

powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Check -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Detail -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

通过标准：首次交互登录进入 ERP 并返回 API-ready；Detail 为已登录/high；活动租约为 0；第二次无凭据复用同一端口、Profile 和 Chrome PID。

若返回图片验证码、短信、滑块、二维码或二次确认：

1. 只在同一已登记 Chrome 中完成该项外部安全验证。
2. 不要在 Chrome 重新输入账号或密码，不要点击普通登录表单，不要复制 Token/Cookie。
3. 完成外部验证后，重新执行同一条交互式 `Login` 命令。
4. 只有页面进入 ERP 且 API 探针成功才算通过；否则按返回的 errorCode/message 反馈。

2026-07-30 已按最终用户路径完成过一次脱敏实机验收：Read-Host 冷启动登录进入 ERP，refresh/probe 均为 HTTP 200，Detail 为已登录/high/API-ready，活动租约为 0，随后 NonInteractive 调用复用同一端口、Profile 和 Chrome PID。仓库不记录任何凭据值。
