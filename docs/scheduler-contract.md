# 统一调度契约

## 用户入口与开发接口

普通用户从 `bsclaw` 中文菜单进入，由交互层自动提交、等待、回查和展示任务结果。普通用户不需要理解或手写 moduleId、action、taskId、manifest 或 JSON。

`task submit/status/result/list`、`service list/check` 和 `--json` 是开发、自动化与审计接口，仅用于机器集成和问题定位。它们与菜单共用同一调度器和服务适配器，不是另一套业务实现，也不能替代用户菜单验收。

代码职责和扩展边界见 [architecture.md](architecture.md)。公开 `UnifiedScheduler` 仅提供任务生命周期门面；预检、执行、回查、恢复和公开投影由独立组件负责，后续接入 Python 工作流不得把逻辑重新堆回 CLI 或调度门面。

## 任务状态

正式状态为：已创建、预检中、等待人工处理、执行中、等待回查、成功、失败、已取消、超时、未验证、阻断。

每次状态变化必须保存 taskId、模块、动作、时间、阶段、错误码、脱敏摘要、人工处理要求、下一步、writeLevel、是否写服务状态和是否执行业务写入。

## 状态持久化

- 当前任务：`data/scheduler/tasks/<taskId>.json`
- 状态审计：`data/scheduler/audit.jsonl`
- 既有服务检查记录：`data/task-records.jsonl`

调度数据只属于统一调度模块，不反向覆盖 PortManager 的资源和登录事实。

正式模块通过预检后由独立 F 盘 Python 执行进程运行，`task submit` 立即返回
taskId，用户可继续查询或取消。取消会写入终态，执行进程检测到取消后停止插件
子进程；超时也会终止插件子进程。程序恢复时只保留仍有活动执行进程的任务。

## 插件输入

调度层通过 UTF-8 JSON stdin 传入：

- protocolVersion
- taskId、moduleId、moduleVersion、action
- parameters
- runMode
- resource（仅 ResourceId）
- writeLevel、readOnly、serviceStateWrite、businessWrite
- timeoutSeconds
- audit（auditId、submittedAt）

插件不得获得密码、Cookie、Token、完整授权头或浏览器存储。

服务插件与业务模块共用该进程协议，但由 manifest `type` 区分。服务插件必须声明 `writesServiceState` 和禁止直接访问边界。PortManager 作为 `resource-service` 只允许通过公开 PowerShell JSON 入口调用；调度层不导入 PSM1，也不读取 SQLite。

## 插件输出

插件 stdout 必须只返回一个 UTF-8 JSON 对象，并包含：

- success
- status
- result
- errorCode
- message
- needsManualAction
- evidence
- businessWritesExecuted
- serviceStateWritesExecuted

缺字段、非 JSON、多余普通输出或入口不存在均属于协议失败。

## 写入等级

- `pure-read`：纯展示，不写服务状态或业务数据。
- `service-state-write`：允许写运行状态、检测时间、临时租约和审计记录；不改 schema、资源定义、凭据、Profile 或外部业务。
- `business-write`：会改变慧策 ERP 等外部业务；当前统一阻断，未来必须先确认、幂等执行并回查。

报告必须分别说明 schema、资源事实源、运行状态、Profile 和外部业务是否变化，禁止再用“数据库完全不变”概括状态检查。

## 结果回查

只读任务可以依据真实插件结果完成。模块声明 `resultCheck.mode=plugin` 时，调度层进入“等待回查”，以 `runMode=verify` 调用同一入口并传递 verificationAction。对扫描代价很高、输出已包含完整只读证据的计划动作，可以声明 `resultCheck.mode=result-contract`：调度层校验第一次真实执行结果的必填字段与只读标志，不重复调用插件。

可能产生业务写入但缺少回查能力时不得判定成功。本阶段所有业务写入均在预检阶段阻断。

## 资源策略边界

`resourcePolicy=none` 仅适用于完全不需要端口资源的只读任务。任何 `pending`、`exclusive`、`same-port-shared` 或 `cross-port` 声明，本阶段统一返回 `RESOURCE_POLICY_PENDING`。

该行为是显式门禁，不代表同端口并发、跨端口并发、排队、租约或锁策略已经实现。

## PortManager 适配

当前真实动作是 `service-check`、`list-resources`、`resource-detail`、`check-resource` 和 `storage-plan`。纯展示动作按 manifest 回查；`check-resource` 执行真实状态检测并声明为 `service-state-write`，使用第一次结果做契约校验，不重复检测。`storage-plan` 遍历大 Profile 的成本较高，因此只执行一次真实扫描，再校验其 dry-run、readOnly 和 totals 契约。

所有业务写入和资源定义变更动作仍不在自动调度白名单。Open/Login 只存在于用户确认后的公共命令路径，不是自动调度动作。
