# BS Claw 服务插件契约

## 边界

统一调度层只读取正式 manifest，并通过独立子进程调用适配器。它不导入服务内部模块，不读取或写入服务数据库、状态文件、Profile 或凭据。

用户交互层只负责菜单、确认、进度和结果展示；所有服务调用仍经过调度器或 PortManager 公共入口。交互层不得导入 PortManager 的 PSM1、读写其 SQLite，或将 PortManager 代码合并到本地层。

正式类型包括 `service`、`resource-service`、`huice-resource-service`、`workflow` 和 `business-module`。只有资料、没有 manifest 的目录只能标记为“资料已发现/未接入执行”。

## 发现

服务 manifest 名为 `bsclaw.service.json` 或 `service.manifest.json`。发现来源为当前 PowerShell 的 `BSCLAW_SERVICE_ROOTS` F 盘目录和 `BSClaw-Local\services`。仅当目录内存在有效 manifest 和真实入口时注册；目录名、README 或脚本本身都不足以注册服务。

## 必填声明

manifest 必须声明 id、名称、版本、type、入口、动作、风险、业务写入、服务状态写入、外部依赖和禁止直接访问边界。

## PortManager 适配

PortManager 是首个 `resource-service`。统一调度只调用其公共入口：

`PortManager-Phase1\port-manager.ps1 -Action <允许动作> -OutputFormat Json -NonInteractive`

当前自动调度白名单：

- `service-check` → `ServiceCheck`；
- `list-resources` → `List`；
- `resource-detail` → `Detail`；
- `check-resource` → `Check`；
- `storage-plan` → `StoragePlan`。

`ServiceCheck`、`List`、`Detail` 和 `StoragePlan` 是 `pure-read`，只展示或盘点，不写 PortManager 运行状态。`Check` 是 `service-state-write`：允许更新运行状态、检测时间、临时租约和审计记录，所以 SQLite 文件哈希可能变化；它不改 schema、资源定义、CredentialRef、Profile 或外部业务。

`Register`、`Edit`、`Delete`、`CleanCache`、`Login`、`Open` 等仍未暴露给自动调度。普通用户菜单只可在明确确认后通过 PortManager 公共入口执行 Open/Login，不能通过改变 action 文本绕过白名单。

## 输出与可插拔性

适配器 stdout 只能输出一个 UTF-8 JSON 对象。返回只保留资源编号、端口、状态、SQLite integrity 和存储汇总；CredentialRef、Profile 路径、浏览器存储及鉴权材料不会进入调度记录。

其他服务可按相同 manifest 和 stdin/stdout 协议接入，无需修改调度核心。PortManager 仍可独立运行和发布；统一调度层不进入当前端口管理 GitHub 发布边界。

## 启动器归属与发布边界

`bsclaw` / `BS Claw` 启动器属于 `BSClaw-Local` 统一调度本地层。PortManager 目录中的同名历史启动文件只用于本机兼容，不属于 PortManager 发布清单，也不得随端口管理仓库推送。PortManager 发布候选只包含端口管理自身代码、文档、测试、适配契约和零数据模板。

调度任务可以记录 `ResourceId` 以关联资源；ResourceId 是业务资源标识，不是 CredentialRef 或凭据。任务、结果和审计均禁止保存账号、密码、Cookie、Token、完整授权头或浏览器存储内容。
