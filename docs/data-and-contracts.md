# 数据模型、契约与状态持久化

## 任务上下文

任务上下文包含：业务目标摘要、规则版本、资源快照引用、认证能力摘要、候选快照引用、幂等键、Action、状态、外部任务引用、结果摘要、恢复原因和审计引用。不得保存密码、Cookie、Token、完整请求头或 Profile 敏感路径。

## 建议表（待 schema 审批）

| 表 | 用途 | 可清理性 |
|---|---|---|
| `selection_tasks` | 任务主状态和输入摘要 | 需按保留策略处理 |
| `selection_candidates` | 候选快照脱敏索引与命中结果 | 可按策略归档 |
| `selection_actions` | Action 执行和外部引用 | 业务记录需保护 |
| `selection_rules` | 规则版本和摘要 | 不可无记录删除 |
| `selection_recoveries` | 未知结果和恢复记录 | 不可静默删除 |
| `selection_audits` | 脱敏审计事件 | 按审计保留策略保护 |
| `schema_migrations` | 本模块迁移版本 | 不可清理 |

正式开发前必须确定主键、唯一键、索引、时间字段、迁移回滚和跨版本兼容；不得修改 PortManager 数据库或复用其 schema。

## Action 契约最小字段

```json
{
  "action": "selection.execute",
  "version": "1",
  "resourceSelectionMode": "single|multi|all",
  "resourceExecutionPolicy": "same-resource-exclusive|cross-resource-parallel|serial|policy-pending",
  "requiresLogin": true,
  "writeRisk": "read|write",
  "supportsCancel": true,
  "supportsRecovery": true,
  "resultReadback": "required"
}
```

未声明执行策略、登录要求、写入风险或回查方法的 Action 不得放行。

## 错误契约

错误至少包含稳定 code、用户消息、技术摘要、阶段、是否可重试、是否需要恢复、事实源时间和下一步。技术摘要必须脱敏。
