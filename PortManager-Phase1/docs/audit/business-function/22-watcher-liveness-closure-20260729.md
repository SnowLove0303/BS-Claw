# Watcher 存活一致性收口（2026-07-29）

## 问题

`HCP-E1880AE9` 曾保存 Watcher PID 4456、旧心跳和已经过期的下次检查时间，但该进程已不存在。旧共享读取链没有验证 PID、启动时间和进程身份，因此 List/Detail 会继续展示假存活信息。

普通 Huice Check 还有一个关联问题：它没有启动 Watcher，却会把 `watcher_error_code` 更新为空，可能掩盖异步维护链已经降级的事实。

## 状态契约

- `port_runtime_states.login_status` 与 API 探针仍是当前登录状态；Watcher 不是真值来源。
- Watcher 健康必须同时满足：PID 存在、启动时间匹配、进程命令是对应 ResourceId 的 Watcher。
- 失活时清空 `watcher_pid`、`watcher_process_start_time`、`watcher_heartbeat_at`、`watcher_next_check_at`，保留 `watcher_last_check_at`，增加失败次数并记录具体错误码。
- 失活标记通过条件更新写回，避免读取与 Watcher 重启并发时覆盖新实例。
- 普通 Check/Login 不清除 Watcher 降级标记；只有携带真实 Watcher PID 的心跳写入才能清除。
- 第一阶段 Watcher 可选。插件发现降级后先执行按需 Check；Open 会尝试启动或复用 Watcher。

## 错误码

- `WATCHER_PROCESS_NOT_FOUND`
- `WATCHER_PROCESS_START_TIME_MISSING`
- `WATCHER_PROCESS_START_TIME_INVALID`
- `WATCHER_PROCESS_START_MISMATCH`
- `WATCHER_PROCESS_IDENTITY_MISMATCH`
