# BS Claw Login 异常中断租约回收结果

## 问题原因

Login、Check、Open、Watch 正常退出时依靠 `finally` 释放 SQLite 租约；进程被外部强制终止时无法执行 `finally`。原读取逻辑只按 `expires_at` 回收，因此 Login 租约可能继续假占用最长 600 秒。

## 最小修复

- 在 HuiceLoginAgent 与 PortManager 共用的 SQLite PowerShell 访问层校验活动租约。
- 只处理本次调用对应 ResourceId。
- PID 不存在时允许回收。
- PID 存在时，以“实际进程启动时间必须早于租约建立时间”确认仍是原进程实例；后来启动的同 PID 视为实例不匹配。
- 活 PID 但启动时间无法确认时保留租约，不做猜测性释放。
- SQLite 通过 leaseId、ResourceId、owner PID、createdAt、taskRef 条件更新原子回收。
- 回收与 `LeaseAutoReclaim` 审计在同一事务中完成。
- 申请新租约前执行回收；若旧进程恰好在检查与申请之间退出，重新核验并最多重试一次。

## 实际验证

隔离资源：`HCP-74DC4A5F / 53394`。

1. 正式 AcquireLease 进程结束且未手工释放：
   - owner PID 已不存在；
   - 下一次 Occupancy 自动回收；
   - `activeLeases=0`；
   - 审计 errorCode 为 `LEASE_OWNER_PROCESS_NOT_FOUND`。
2. 存活 Watch 租约：
   - Occupancy 查询期间保持活动，不被回收；
   - 外部终止该测试进程后，下一次 Occupancy 才回收；
   - Chrome 未被终止。
3. 真实 Login 外部终止：
   - 起点为 `login-required`；
   - 在安全输入等待节点观察到 Login 租约；
   - 外部终止 PID 16064；
   - 下一次 Occupancy 自动恢复为 0；
   - 随后 Check 返回 `login-required`，不是 `RESOURCE_BUSY`；
   - Chrome PID 32116 前后一致；
   - Watcher PID 16028 前后存活。
4. Open 回归：
   - 成功；
   - 最终活动租约 0；
   - Profile 字节数前后均为 261459664，变化 0。
5. 基础验证：
   - PowerShell/JS/Python 静态验证 8/8；
   - SQLite `integrity_check=ok`；
   - schemaVersion=36。

## 未通过项

清除隔离资源会话后，使用现有第一组测试凭据恢复完整 Login 未通过：

- Login 最终为 `AUTO_LOGIN_TIMEOUT`；
- 页面仍为 `login.huice.com`；
- 页面最终企业账号框长度为 8，源长度为 7；另外两项长度为 9 和 12；
- 未进入 ERP，不能验证本轮后的 API ready 和二次复用；
- 失败后活动租约已正常归零。

该问题不是 `RESOURCE_BUSY` 或租约遗留造成，但它使“已通过登录/ERP/API/复用回归仍通过”这一总体验收条件未满足。不得将租约专项通过描述为完整登录链通过。

## 用户/审计复测

固定流程见：

`F:\XIANGMU\BS Claw\PortManager-Phase1\docs\stale-login-lease-recovery-test.md`

自动中断验收命令：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\tests\test-stale-login-lease-recovery.ps1" -ResourceId HCP-74DC4A5F
```

## 回滚

修改前备份：

`F:\XIANGMU\BS Claw\_audit-backups\20260730-103050-stale-login-lease-fix`

优先只回滚三个源码文件和新增测试/文档。数据库备份仅用于灾难恢复；覆盖数据库会丢失备份时间点之后的审计记录，必须先停止相关进程并再次备份。
