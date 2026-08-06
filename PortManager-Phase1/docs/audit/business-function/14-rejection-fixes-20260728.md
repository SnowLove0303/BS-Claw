# 打回优化复测记录（SQLite/检测/租约）

范围仅为 PortManager-Phase1；未接入 BS Claw 主系统，未提交或推送。

## 本次修复

| 问题 | 修复结果 |
|---|---|
| 登录检测 JSON 双真源 | 新增 SQLite `login_detection_tasks`（schema 14/15）；检测启动、完成、取消、超时均写 SQLite。`login-detections.json` 仅迁移/备份。 |
| 无鉴权规则误判 | 适配器明确 `authenticatedEvidenceAvailable=false`；没有真实鉴权证据时保持未知，未伪造已登录。 |
| 检测进程生命周期 | 任务保存 attemptId、processId、超时、错误、日志路径；取消会回收进程并收口任务；编辑/删除在写锁内拒绝 running 检测任务。 |
| 旧元数据迁移 | 首次迁移安全导入 leases/login-detections 元数据，过期租约收口；写入 `legacy-metadata-migrated.json` 标记，JSON 保留。 |
| schemaVersion/checksum | 对外 `schemaVersion` 使用 `MAX(schema_migrations.version)`；启动校验全部 migration checksum，不一致停止写入。 |
| 租约入口 | 新增 `AcquireLease`、`ReleaseLease`、`Occupancy` JSON/PowerShell 入口；释放幂等，申请校验资源和启用状态。 |
| 统一追踪字段 | JSON envelope 固定包含 resourceId、leaseId、auditId、taskId（无值时为 null）。 |

## 实际回归

独立目录：`data\test-runs\lease-contract-20260728-c`。

- 租约申请后 Edit/Delete 返回 `PM_RESOURCE_LEASED`；Open 同样被租约拒绝。
- 释放租约后 Edit 成功；Occupancy 返回租约为空。
- SQLite 任务 `running` 时 Delete 返回 `PM_LOGIN_DETECTION_ACTIVE`；取消后任务变为 `cancelled`，随后删除成功。
- 登录检测启动返回 taskId/attemptId，运行目录未生成 `login-detections.json`。
- 真实端口不可达时 Check/CheckAll 保持真实失败状态。

## 未完成/未验证

真实 Chrome CDP 成功打开、慧策页面匹配、真实鉴权证据、登录态复用仍未验证；适配器没有可靠 authenticatedEvidenceRules，因此不能判定“已登录”闭环通过。完整中文向导大回归仍按超时策略中止。
