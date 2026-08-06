# Login 异常中断租约回收测试

本流程只验证：慧策 Login 进程被外部终止后，下一次 Occupancy、Check、Open 或 Login 能自动回收已确认死亡的租约，不需要人工执行 ReleaseLease。

## 前置条件

1. 只使用隔离资源 `HCP-74DC4A5F`，不得清理或改动其他正式资源。
2. 端口 53394 的原 Chrome/Profile 已启动。
3. 隔离资源已由授权测试流程清除慧策会话，以下命令返回 `login-required`：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\HuiceLoginAgent\login-agent.ps1" -Action Check -ResourceId HCP-74DC4A5F -OutputFormat Json -NonInteractive
```

## 自动中断与恢复验证

执行：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\tests\test-stale-login-lease-recovery.ps1" -ResourceId HCP-74DC4A5F
```

脚本只终止它自己创建的 Login 子进程，不终止 Chrome、Watcher 或其他资源进程。通过标准：

- `success=true`
- `ownerAliveAfterKill=false`
- `activeLeasesAfterRecovery=0`
- `checkStatusAfterRecovery=login-required`
- `checkErrorCodeAfterRecovery` 不是 `RESOURCE_BUSY`
- Chrome PID 前后一致
- 测试前已存活的 Watcher 测试后仍存活

## 恢复真实登录

以下脚本只用于验证重定向 stdin 的受控凭据传输兼容性。`Console.IsInputRedirected` 会进入不同于 PowerShell `Read-Host` 的输入分支，因此其登录结果不得作为最终用户 Login 主验收结论。正式用户验收必须按 `HuiceLoginAgent\docs\manual-test.md` 运行真实交互命令；正式集成仍必须由 PortManager 通过 CredentialRef 和受控内存凭据提供器传入。

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\tests\invoke-isolated-huice-login.ps1" -ResourceId HCP-74DC4A5F -CredentialFile "F:\XIANGMU\BS Claw\PortManager-Phase1\测试账号.txt"
```

该兼容性脚本的输出只说明 stdin 传输分支结果，不定义最终 Login 通过或失败。最终登录通过标准以真实 `Read-Host` 流程为准：

- `success=true`
- `status=logged-in-api-ready`
- `refreshHttpStatus=200`
- `probeHttpStatus=200`
- `requiredProbeFieldsPresent=true`

随后复核：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action Detail -ResourceId HCP-74DC4A5F -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action Occupancy -ResourceId HCP-74DC4A5F -OutputFormat Json -NonInteractive
```

若恢复 Login 未返回 `logged-in-api-ready`，这是登录链回归失败，不得将租约回收通过包装成整体验收通过。反馈时只提供 `errorCode`、脱敏 message、页面主机、HTTP 状态、资源编号和活动租约数，不提供账号、密码、Cookie 或 Token。
