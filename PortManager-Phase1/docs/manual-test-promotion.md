# PortManager 推广候选人工测试

仓库级最终流程见 `..\..\docs\manual-validation.md`。以下命令不依赖当前工作目录：

```powershell
$RepoRoot = "F:\BS-Claw"
$ResourceId = "<隔离测试资源编号>"

powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId $ResourceId -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action HuiceCheck -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action CachePlan -ResourceId $ResourceId -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "$RepoRoot\PortManager-Phase1\port-manager.ps1" -Action DeploymentCleanPlan -ResourceId $ResourceId -OutputFormat Json -NonInteractive
```

CachePlan 与 DeploymentCleanPlan 只能预览，不删除数据。真实 CleanCache 必须关闭对应 Chrome、使用精确确认文本并写审计；它不能用于退出登录。
