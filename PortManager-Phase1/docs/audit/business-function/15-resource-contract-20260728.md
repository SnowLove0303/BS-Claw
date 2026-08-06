# 资源调用契约

PowerShell 入口统一使用同一数据库和资源编号：

```powershell
.\scripts\port-manager.ps1 -Action List -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action Detail -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action Check -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action CheckAll -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action Open -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action AcquireLease -ResourceId HCP-XXXXXXXX -TaskRef task-1 -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action ReleaseLease -LeaseId <leaseId> -OutputFormat Json -NonInteractive
.\scripts\port-manager.ps1 -Action Occupancy -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
```

JSON envelope 固定包含 `success`、`message`、`data`、`nextAction`、`errorCode`、`resourceId`、`leaseId`、`auditId`、`taskId`。租约申请在数据库事务内校验资源存在、启用状态和占用；Edit/Delete/Open 会拒绝活动租约。
