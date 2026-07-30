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

外部验证码、短信、滑块、二维码或二次确认未自动完成时标记为外部阻断。不要在反馈中提供账号、密码、Token、Cookie 或完整授权头。
