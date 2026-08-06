# 执行环境复用与登录同步（当前轮）

运行时数据库固定为 `data/port-manager.sqlite3`，当前 schema migration 版本为 36。SQLite 是唯一真源；`ports.json`、`leases.json`、`login-detections.json` 仅用于迁移或备份。

## 资源绑定

每个资源通过 `resourceId + hostName + port + browserProfileDirectory` 绑定稳定执行环境。运行状态额外保存 `browserPid`、`processStartTime`、`profileFingerprint`、`sessionState`、`lastOpenAt`、`lastOpenResult`，以及 watcher PID、启动时间、心跳、下次检查、失败次数和错误码。Open 会校验 Chrome 命令行中的调试端口和 Profile；不匹配时返回“已有会话未登记或资源占用”，不会新建未登录 Profile。

## 登录同步

Open 成功后启动一次真实检测，并启动独立 `scripts/login-state-watcher.ps1`。watcher 每 10 分钟通过正式 `Check` 入口回读真实 Chrome 页面并写入 SQLite。当前适配器已启用受控鉴权证据规则；只有 HuiceLoginAgent 的实时鉴权续接与只读 API 探针成功时才判定“已登录 / API-ready”，端口或页面存在本身不能替代鉴权证据。删除前会停止 watcher；检测任务仍按 SQLite running 状态保护资源。

## 迁移与回滚

当前 migration 版本以 `schema_migrations` 最大版本为准；本轮新增执行环境绑定字段，启动时校验 checksum。迁移前备份位于 `data/migrations`。回滚时停止 watcher/worker，恢复对应 F 盘 SQLite 备份并执行 `PRAGMA integrity_check`；不删除原 JSON。

## 当前未验证

真实慧策账号鉴权证据、手动登录后自动变为“已登录”、关闭后同 Profile 自动恢复、未登记活动会话绑定提示，必须在用户真实环境复测；本轮不得以页面标题、URL、端口或 Chrome 可达替代登录证据。
