# SQLite 当前契约（2026-07-29）

运行数据库位于模块根目录 `data\port-manager.sqlite3`，当前 schemaVersion 为 **36**。启动时校验 `schema_migrations` checksum；不一致时停止写入。数据库运行文件不进入 Git。

状态边界：

- `port_resources`：资源定义事实源。
- `port_runtime_states`：端口、浏览器、页面、登录、API、Watcher 和 Profile 指标的当前事实源。
- `login_session_events`：追加式脱敏登录证据。
- `login_sessions`：旧兼容投影，只能由当前状态单向刷新，不得反向覆盖。
- `resource_leases`：短期并发租约；过期或结束后收口。
- `login_detection_tasks`：异步检测任务记录。
- `credential_profiles`：只保存 CredentialRef、类型和脱敏摘要。
- `audit_records`：正式操作与失败审计。
- `schema_migrations`：迁移版本与 checksum。

不可由普通清理删除：资源定义、schema、CredentialRef、脱敏账号摘要、审计、登录事件和正式数据库。可重建：PID、Watcher 心跳、过期租约、临时探针结果、日志、测试产物和 Chrome 可再生缓存。

迁移到新机器后必须重新发现 Chrome 路径、端口占用、PID、Watcher 和登录状态新鲜度，并重新执行 API 探针。需要复用登录态时，单独受控迁移对应 Profile 的非缓存数据；通用发布包不得包含真实 Profile 或秘密。

当前已验证：`PRAGMA integrity_check=ok`、schemaVersion=36、正式资源状态回读、兼容投影一致和活动租约收口。未由开发代替用户执行：重新输入真实账号密码的完整 Login。
