# 当前状态契约与动态存储分层（2026-07-29）

## 登录状态事实源

`port_runtime_states` 是端口与登录当前状态的唯一事实源。PortManager List/Detail/Check 和 HuiceLoginAgent List/Check/Login 都通过共享 SQLite 服务读取或写入该表。

`login_session_events` 是只追加的脱敏历史事件，不参与当前状态判定。

旧数据库中的 `login_sessions` 不属于当前 schema。为避免旧查询误读，其现有表和历史行被保留，但由共享 SQLite 服务从 `port_runtime_states` 单向刷新为兼容投影。它不能反向更新事实源；新数据库不需要创建该表。

Watcher PID、启动时间、心跳和下次检查时间属于可再生运行状态。共享 SQLite 读取入口会校验真实进程实例；失活后清除假存活字段并记录 `watcherErrorCode`，但不覆盖有真实证据的登录状态。第一阶段 Watcher 是可选维护链：插件可按需 Check 降级，Open 可重新启动或复用 Watcher。

## 动态存储分层

容量必须在采集时间点动态计算，不得把任一瞬时 Profile 大小写成稳定结论：

1. 代码本体：脚本、模块、配置与文档；不包含运行数据、Profile、日志和测试运行目录。
2. SQLite 事实源：资源定义、当前状态、迁移、CredentialRef、脱敏账号摘要和正式审计。
3. 非缓存 Profile：Cookies、Local/Session Storage、Preferences 等用户环境与登录复用所需数据，不允许普通清理删除。
4. 可再生缓存：由 `Get-PMProfileMetrics` 按已识别缓存目录动态统计；允许增长，不污染事实源，可由 Chrome 重新生成。
5. 历史测试/运行产物：`data\test-runs`、`tests\runtime`、`runtime`、临时日志等；清理前仍需独立清单、影响说明和用户授权。

计算关系：

- `nonCacheBytes = sizeBytes - cacheBytes`
- `cacheRatio = cacheBytes / sizeBytes`
- 所有数值均应同时记录采集时间。

## 本次只读快照

采集时间：2026-07-29 20:21:28 +08:00。

- 两模块源码与文档扫描：110 个文件，584,856 bytes。
- SQLite 事实源：475,136 bytes。
- `huice-53392`：总量 3,145,545,785 bytes；可再生缓存 3,100,434,331 bytes；非缓存 Profile 45,111,454 bytes。
- 全部登记 Profile：总量 4,101,430,337 bytes；可再生缓存 3,803,857,215 bytes；非缓存 297,573,122 bytes；缓存占比 92.74%。
- 已识别历史测试/运行目录：`data\test-runs` 397,116,770 bytes，`tests\runtime` 634,512,030 bytes，`runtime` 245,453,378 bytes。

这些数字只是该时间点的验证证据。Chrome 后续执行会改变缓存大小，复核时必须重新运行动态统计。

## 清理边界

普通 Open、Check、Login、List 不调用缓存清理。底层清理默认 dry-run；真实执行必须显式确认、限定 Profile 根路径、确认 Profile 未运行并先写 F 盘审计记录。数据库、资源定义、CredentialRef、正式审计、Cookies、Local/Session Storage 和 Preferences 不属于清理目标。
