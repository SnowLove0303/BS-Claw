# 模块 Manifest 契约

统一调度读取 `bsclaw.module.json`、`module.manifest.json`、`bsclaw.service.json` 或 `service.manifest.json`。模块搜索根目录来自当前 PowerShell 会话的 `BSCLAW_MODULE_ROOTS`；服务搜索根目录来自 `BSCLAW_SERVICE_ROOTS`。多个 F 盘目录使用 Windows 分号分隔。

## 必填顶层字段

- schemaVersion
- moduleId
- name
- version
- type：`service`、`resource-service`、`huice-resource-service`、`workflow` 或 `business-module`
- riskLevel
- businessWritesEnabled
- entry
- actions
- capabilities（面向用户的真实能力清单）

`schemaVersion` 当前必须为整数 `1`，`businessWritesEnabled` 必须为布尔值。
服务类型还必须声明布尔值 `writesServiceState` 和非空 `prohibitedDirectAccess`。

## entry

- runtime：`python` 或 `powershell`
- path：模块目录内的真实相对入口路径

入口路径不得越过模块目录。

## action

每个动作必须声明：

- id
- mode：`read-only`、`service-state-write` 或 `write`
- writeLevel：`pure-read`、`service-state-write` 或 `business-write`
- requiresHuiceResource
- resourcePolicy：`none`、`pending`、`exclusive`、`same-port-shared` 或 `cross-port`
- timeoutSeconds
- 可选 resultCheck

`pure-read` 只展示数据；`service-state-write` 可以更新服务运行状态、检测时间、临时租约和审计记录，但不能修改 schema、资源定义、凭据、Profile 或外部业务；`business-write` 会改变慧策 ERP 等外部业务，必须具备确认、幂等和回查契约。

`requiresHuiceResource` 必须为布尔值。声明 `mode=write` 时，
`businessWritesEnabled` 必须同时为 `true`；但统一调度第一阶段仍会在预检阶段
阻断所有业务写入。

## 用户能力元数据

每个 capability 声明用户名称、模块类型、操作分类、writeLevel、是否选择资源、是否需要登录门禁、是否确认、确认文案、进度文案、结果视图、失败下一步以及重试/取消/恢复能力。菜单和任务中心读取这些元数据；新增 Python 工作流不应复制一套硬编码交互。

未来慧策 HTTP 工作流还需声明资源选择、登录门禁、dry-run/参数预览、业务写入确认、结果回查，以及登录失效、权限不足、字段缺失、业务校验、接口、网络、外部风控和程序缺陷的错误分类。当前没有真实业务模块，因此不显示业务执行入口。

同一个搜索范围内不得出现重复 `moduleId`。重复注册、入口越界、字段类型错误
或动作重复都视为 manifest 无效。

资料目录没有 manifest 时只显示“资料已发现/未接入执行”。manifest 无效、入口不存在或动作未声明时，任务必须阻断。

## 当前发布边界

本阶段附带真实 PortManager 服务适配 manifest，但不附带任何业务插件，也不提供示例、Mock 或占位插件。真实业务模块必须由后续业务开发按该契约独立交付和验收。
