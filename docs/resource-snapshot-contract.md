# ResourceSnapshot 与 ResourceContext 契约

本文件定义 BSClaw-Local 对 PortManager 公共 JSON 结果的唯一脱敏投影。BSClaw-Local 不读取 PortManager SQLite、PowerShell 内部模块、Profile 或凭据。

## ResourceSnapshot

列表、详情、检查、任务结果、任务中心和 `status/resources` 使用同一组字段：

`resourceId`、`resourceName`、`port`、`enabled`、`connectionStatus`、`browserStatus`、`pageStatus`、`loginStatus`、`apiStatus`、`confidence`、`checkedAt`、`snapshotAt`、`freshness`、`statusSource`、`nextAction`、`occupancy`、`lease`。

`freshness` 只允许由检查时间计算为 `fresh`、`stale`、`never-checked` 或 `invalid-time`。列表缓存不能覆盖一次新的公开 Check 结果。

## HuiceExecutionContext

业务模块只接收调度器注入的脱敏 `executionContext` 和 `port-manager-public-json` 服务句柄标识。业务模块不得自行维护资源清单、任务、租约、浏览器、Profile、凭据或数据库连接。

当前没有真实慧策选品业务 manifest 或入口，因此不显示为可执行模块。选品业务接入前必须提供真实 manifest、入口、输入、确认、只读/dry-run、写入锁、幂等和写后回查契约。

