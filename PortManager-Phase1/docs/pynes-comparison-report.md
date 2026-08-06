# Pynes 借鉴对照报告

参考基线：`SnowLove0303/pynes-desktop`，提交 `7adc8f4f26d19d1ac386d06ff3c4ed64f16b4ae6`。

## 已读取路径

- `src/main/runtime/chrome-port-service.ts`
- `src/main/runtime/browser-session-keeper.ts`
- `src/connectors/huice-wdt/auth.ts`
- `src/core/persistence/browser-port-repository.ts`
- `src/core/persistence/mysql-schema.ts`
- `docs/系统功能需求记录.md`，重点为 `REQ-20260702-021`

## 对照

| Pynes 原实现路径 | 借鉴原则 | BSClaw 实现 | 不直接复制的原因 |
|---|---|---|---|
| `chrome-port-service.ts` | 参数数组启动 Chrome；平台端口与会话稳定绑定 | PowerShell `Start-Process -ArgumentList` 数组传参；启动后反查 Win32 命令行、PID、启动时间和 Profile 指纹 | BSClaw 不复制 Node 生命周期和多平台固定端口模型，资源由 resourceId 管理 |
| `chrome-port-service.ts` | runtime/platform/session 稳定 Profile | SQLite `browserProfileDirectory` 是唯一来源，强制 F 盘边界 | 不复制递归删除 Profile 和默认目录回退风险 |
| `browser-session-keeper.ts` | 只检查已登记且端口仍打开的会话，异常写回数据库 | 独立 `login-state-watcher.ps1`，绑定 resourceId、RuntimeRoot、ProjectRoot、PID 和启动时间，周期回写 SQLite | 不复用 Pynes 的 MySQL、selected session 或 UI 调度方式 |
| `auth.ts` | live CDP 页面优先；业务页和同源鉴权检查分层 | HuiceLoginAgent 通过实时同源鉴权续接与只读 API 探针形成受控证据，PortManager 只保存脱敏状态摘要 | 不复制 Pynes 的 cookie/token 明文快照 |
| `browser-port-repository.ts` / `mysql-schema.ts` | 配置、运行状态、鉴权状态、检查时间分层持久化 | SQLite `port_resources`、`port_runtime_states`、`login_state_checks`、`resource_leases`、`audit_records` | 当前阶段明确 SQLite，未来可迁移；不引入 MySQL |
| `REQ-20260702-021` | live 状态不能被历史快照覆盖 | 每次 Check/Open 重新读取 CDP 页面并更新 runtime；旧状态不作为当前鉴权证据 | 仅保留 BSClaw 必要字段和错误码契约 |

## SQLite 字段映射

- 资源身份：`resource_id`、`host_name`、`port`、`browser_executable`、`browser_profile_directory`
- 执行环境：`browser_pid`、`process_start_time`、`profile_fingerprint`、`session_state`
- 登录状态：`login_status`、`login_evidence_json`、`login_checked_at`、`login_detection_state`
- watcher：`watcher_pid`、`watcher_process_start_time`、`watcher_heartbeat_at`、`watcher_last_check_at`、`watcher_next_check_at`、`watcher_failure_count`、`watcher_error_code`
- 打开状态：`last_open_at`、`last_open_result`

不保存 Cookie 值、Token、密码、完整授权头或完整浏览器存储。后续自动登录只能通过 Credential Ref/受控凭据库扩展。

## 慧策鉴权证据边界

Pynes 的 `auth.ts` 读取同源页面存储、Cookie、shopId，并进一步检查业务页/API。BSClaw 当前适配器已有一条启用的受控鉴权证据规则：HuiceLoginAgent 在同一已登记 Profile 中完成鉴权续接与只读 API 探针，只有二者成功才写入“已登录 / API-ready”。页面标题、URL、CDP 可达和页面匹配仍不能替代该证据。

## 真实证据与剩余风险

- Launch 含空格 Profile 已真实验证：端口 53392、Chrome PID 29128、Profile 路径完整一致。
- 本段是早期对比阶段的历史结论，当时 SQLite migration 为 32；不得作为当前运行契约。当前 schema migration 为 36，正式依据见 `docs/sqlite-schema-current.md`，运行时仍必须以实际 `schema_migrations` 和 `PRAGMA integrity_check` 为准。
- watcher PID、启动时间、心跳和下次检查已能写入 SQLite；长期异常退出/重启恢复仍需继续回归。
- 手动登录后的“已登录”、登录失效、同源业务 API 鉴权和会话复用尚未验证，不能宣称本模块通过。
