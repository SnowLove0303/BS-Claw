# 数据契约

PortManager 的 `data\port-manager.sqlite3` 是唯一运行时数据库和资源/状态真源：

- `port_resources`：资源定义、端口、Profile、CredentialRef 与脱敏账号摘要。
- `port_runtime_states`：PortManager List/Detail/Check 对外读取的当前状态。
- `login_session_events`：只追加脱敏登录证据历史。
- `resource_leases`：Login、Check、Open、Watch 等跨进程操作租约。
- `credential_profiles`：只保存 CredentialRef、类型与脱敏摘要。
- `login_sessions`：旧数据库可选兼容投影。Check/Login 保存当前状态时由 `port_runtime_states` 单向刷新，供旧查询过渡使用；禁止作为当前状态写入入口或反向覆盖事实源。

禁止持久化密码、Token、Cookie、完整授权头、验证码、浏览器存储内容或原始登录响应。Schema 与 checksum 由 PortManager 共享 SQLite 服务维护。

正式调用契约为 `ResourceId + CredentialRef`：PortManager 负责安全匹配、凭据获取与租约决策，LoginAgent 只消费一次性内存凭据或受控标准输入并在 finally 清理。插件、调度器、MCP 与其他 UI 模块只能获得 ResourceId 和非秘密状态，不得获得凭据。

跨机器迁移时必须保护资源定义、Schema、迁移记录、CredentialRef、脱敏账号标识和正式审计记录；PID、心跳、过期租约、探针结果、缓存和测试产物属于可再生运行数据，应在新机器重新检测或重建。

状态读写关系：

- Huice Login/Check：读取 `port_resources` 与 `port_runtime_states`；成功或失败结果写入 `port_runtime_states`，并追加 `login_session_events`。
- Huice List：只通过共享 SQLite 服务读取 `port_resources + port_runtime_states`。
- PortManager Check：检测后保存 `port_runtime_states`；如旧 `login_sessions` 存在，同时刷新其兼容投影。
- PortManager List/Detail：读取 `port_resources + port_runtime_states`，不以 `login_sessions` 判定状态。

Watcher 是可选的异步维护进程，不是登录状态事实源。任何读取都会同时校验 `watcherPid`、进程启动时间和命令身份：

- 校验通过：保留 PID、心跳和下次检查时间。
- 进程不存在、PID 被复用、启动时间不匹配或进程身份不匹配：清空无效 PID、启动时间、心跳和下次检查时间，保留最后一次真实检查时间，并写入明确的 `watcherErrorCode`。
- Watcher 失活不反向修改已经有真实证据的登录状态；它表示异步维护链路降级。
- 插件调度发现 Watcher 失活或登录检查时间超过自身新鲜度策略时，必须先调用绝对路径 Check 获取实时状态。Open 会尝试启动或复用 Watcher；第一阶段不要求 Watcher 永久常驻。
