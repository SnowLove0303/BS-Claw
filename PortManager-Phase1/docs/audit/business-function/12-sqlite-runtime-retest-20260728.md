# SQLite 运行时复测记录（2026-07-28）

## 范围

本次只复核独立 `PortManager-Phase1` 的 SQLite 真源、迁移、状态和租约闭环；不接入 `BS Claw\System`，不宣称真实慧策鉴权成功。

## 已真实验证

| 项目 | 结果 | 证据 |
|---|---|---|
| 空库初始化/List | 通过 | `data\test-runs\sqlite-empty3-20260728\data\port-manager.sqlite3`；退出码 0 |
| 旧真实 JSON 迁移 | 通过 | `data\test-runs\sqlite-migration2-20260728\data\migrations`；资源 `HCP-2BD964AC` 保留，原 JSON 未删 |
| 注册与跨进程 List | 通过 | `data\test-runs\sqlite-register-20260728`；数据库读取到新资源 |
| Edit JSON | 通过 | `data\test-runs\sqlite-edit-20260728`；stdout 可解析纯 JSON，备注字段已纳入 SQLite |
| Delete JSON/历史归档 | 通过 | `deleted_resource_history` 保存删除资源快照、登录检测和审计 JSON |
| Check 失败状态 | 通过 | 业务回归 RG-010，List/Detail 可回读最新失败状态 |
| Open 失败收口 | 通过 | 业务回归 RG-011，租约数为 0；真实 Chrome 失败回收 RG-014 通过 |
| 登录页状态 | 通过 | 登录回归 LS-003/004/006：真实页面判定“未登录”，无鉴权证据不判“已登录” |
| 静态/主系统边界 | 通过 | 静态 6/6；主系统仍为 `agent/bootstrap-bsclaw`、HEAD `b1c668078d8959793ba2f4698efc751b9e315567` |

## 未完成/未验证

- 完整业务回归在首次中文向导子进程处超时，已按策略回收；最新失败证据：`data\audit-evidence\business-regression-20260728-192252-b014a724ef164051b950bdd4d6d9ae5c`。不能把 RG-013 并发租约、中文向导、完整 CheckAll 和重启恢复标为通过。
- 真实慧策鉴权成功证据、Cookie/Local Storage 登录复用、自动登录和 10 分钟调度未验证。

## 数据库现状

最新中止回归目录的 SQLite 查询显示：schema migration 13 个版本；核心表及 `deleted_resource_history` 存在；资源 2 条、active 租约 0 条、审计 12 条。数据库位于 F 盘，未使用 C 盘依赖或缓存。

## 回滚

代码回滚点为未提交基线 `f5663dbc3d53d7dcf037ba1afe600452c6d88e97`。数据回滚使用对应运行目录 `data\migrations\pre-sqlite-baseline.json` 和 `legacy` 副本；不删除现有 `data\ports.json`。本轮未提交、未推送。
