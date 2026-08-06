# PortManager Phase1 资源底座契约（2026-07-29）

## 1. 边界

第一阶段提供资源登记、端口/Profile复用、真实状态检测、慧策登录与API只读探针、共享租约、审计和SQLite持久化。它不提供插件编排、长期Watcher监督、高风险写入、业务幂等、写后回查、UI或发布。

## 2. 资源事实源

`port_resources` 是资源定义事实源。插件只按 `resourceId` 选择资源，不以PID、窗口标题或临时端口扫描结果替代资源定义。

插件需要读取：

- `resourceId`、`enabled`、`hostName`、`port`、`connectionMode`
- `browserExecutable`、`browserProfileDirectory`
- `platformUrlPatterns`、`loginPagePatterns`
- `credentialRef`、`maskedAccountSummary`、`loginAutomationState`
- `sessionPolicy`

插件不得读取或持久化密码、Token、Cookie、完整授权头和浏览器存储内容。

`profileFingerprint`、`browserPid`、`processStartTime`、Watcher字段和登录字段来自 `port_runtime_states`，属于当前运行状态，不是资源定义。

## 3. 执行前状态

`port_runtime_states` 是唯一当前状态真源。`login_session_events` 是只追加历史；旧 `login_sessions` 仅为单向兼容投影，不能反向覆盖当前状态。

状态分类：

| 分类 | 条件 | 调度动作 |
|---|---|---|
| ready | 资源启用、端口/浏览器/Profile绑定正确、`已登录 + logged-in-api-ready + high`，且本次按需Check成功 | 可在取得共享租约后执行只读任务 |
| degraded-ready | 登录/API/置信度满足ready，但Watcher失活或不存在 | 先按需Check；成功后可执行，不能把Check当作Watcher已恢复 |
| needs-login | 未登录、登录已失效、登录页、Token/API探针失效 | 调用Login恢复；需要凭据时必须有CredentialRef并由用户安全输入 |
| unavailable | 资源禁用、端口不可连接、浏览器不可连接、Profile不存在/绑定不一致、页面错误 | 不执行；先修复资源或运行环境 |

`HCP-E1880AE9` 的 `sessionPolicy.recheckBeforeUse=true` 且 `maxSessionAgeSeconds=0`，表示每次插件执行前都必须按需Check，不允许盲用数据库旧成功状态。

## 4. 插件调度前最小判断

1. 按ResourceId读取资源，确认启用、端口、Profile和平台类型。
2. 检查是否存在活动租约；有租约则返回`RESOURCE_BUSY`，不得并发穿透。
3. 执行Huice Check或PortManager Check，取得本次真实状态。
4. 仅在`已登录 + logged-in-api-ready + high`时进入后续任务。
5. Watcher失活时允许按需Check降级；Watcher健康不能替代本次Check。
6. 需要Login时调用绝对路径Login，不得向插件传递明文密码。
7. 高风险写入下一阶段必须增加显式确认、幂等键、审计、结果回查和失败补偿；第一阶段不授权写入业务。

## 5. Watcher

Watcher是可选异步维护进程，不是登录事实源。健康条件是PID存在、启动时间匹配、命令身份和ResourceId匹配。失活时清除PID/心跳/nextCheck，保留lastCheck并写errorCode。

按需Check只刷新登录状态，不恢复Watcher。PortManager Open会尝试启动或复用Watcher；下一阶段如果要求无人值守，必须增加独立监督、有限重启、退避和告警。

## 6. Login

- 已登录ERP：复用同一端口/Profile，执行鉴权续接和只读API探针。
- 产品选择页：自动进入旺店通ERP3.0，不提示账号密码。
- 真实未登录：PowerShell依次安全读取企业账号、用户账号和不回显密码，通过真实HTTP Login API登录。
- 安全验证：只在同一Chrome中完成人工步骤，程序继续检测，不复制Token/Cookie。
- 成功：写`port_runtime_states`、追加`login_session_events`并刷新可选旧投影。
- 失败：返回分类`errorCode/message/nextAction`，不得保留虚假成功状态。

完整密码Login仍需用户在明确清除/失效登录态后人工验收；第一阶段收口不主动破坏当前有效会话。

## 7. 数据库与迁移

当前schema版本为36，migration checksum启动时强制校验。

必须保护：

- `schema_migrations`、`port_resources`、`credential_profiles`
- `audit_records`、`login_session_events`、`deleted_resource_history`
- 作为当前真源的`port_runtime_states`

可再生运行状态包括PID、Watcher心跳、过期租约、探针结果和Profile metrics；它们可以重新检测，但普通清理不得直接清空。

跨机器迁移至少保留权威SQLite、迁移代码、CredentialRef和审计；如需复用登录会话还要安全迁移对应Profile。浏览器绝对路径、PID、端口占用和Watcher必须在新机器重新发现或验证，不能沿用旧机器运行值。

## 8. 清理与存储

Chrome必要缓存允许动态增长，不是缺陷。非缓存Profile用于会话复用，普通路径不得删除。

缓存清理只允许显式维护调用：默认dry-run、精确确认、Profile根路径校验、运行中拒绝、F盘审计。普通Open/Check/Login/List不调用清理。

事实源和运行数据必须分开统计：代码本体、SQLite、非缓存Profile、可再生缓存、历史测试/运行产物。所有容量都要记录采集时间，不能作为稳定常量。

## 9. 绝对路径命令

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\HuiceLoginAgent\login-agent.ps1" -Action List -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\HuiceLoginAgent\login-agent.ps1" -Action Check -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\HuiceLoginAgent\login-agent.ps1" -Action Login -ResourceId HCP-E1880AE9
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\scripts\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\scripts\port-manager.ps1" -Action Check -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\scripts\port-manager.ps1" -Action Open -ResourceId HCP-E1880AE9 -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
```
