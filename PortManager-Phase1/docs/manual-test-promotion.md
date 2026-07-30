# PortManager 推广候选人工测试

仓库级最终流程见 `..\..\docs\manual-validation.md`。以下命令不依赖当前工作目录：

```powershell
$RepoRoot = "F:\BS-Claw"
$ResourceId = "<隔离测试资源编号>"

powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId $ResourceId -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action HuiceCheck -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId $ResourceId
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action CachePlan -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action DeploymentCleanPlan -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

CachePlan 与 DeploymentCleanPlan 只能预览，不删除数据。真实 CleanCache 必须关闭对应 Chrome、使用精确确认文本并写审计；它不能用于退出登录。

Login 已登录时直接复用且不读取凭据；真实未登录时在 PowerShell 依次输入企业账号、操作员账号、不回显密码，并输入“同意”。若出现验证码、短信、滑块、二维码或二次确认，只在同一登记 Chrome 完成该项外部验证，然后重跑同一 Login；不要在 Chrome 重输账号/密码、点击普通登录表单或复制 Token/Cookie。
