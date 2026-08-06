# BS Claw 服务插件契约

## 边界

统一调度层只读取正式 manifest，并通过独立子进程调用适配器。它不导入服务内部模块，不读取或写入服务数据库、状态文件、Profile 或凭据。

用户交互层只负责菜单、确认、进度和结果展示；所有服务调用仍经过调度器或 PortManager 公共入口。交互层不得导入 PortManager 的 PSM1、读写其 SQLite，或将 PortManager 代码合并到本地层。

正式类型包括 `service`、`resource-service`、`huice-resource-service`、`workflow` 和 `business-module`。只有资料、没有 manifest 的目录只能标记为“资料已发现/未接入执行”。

## 发现

服务 manifest 名为 `bsclaw.service.json` 或 `service.manifest.json`。发现来源为当前 PowerShell 的 `BSCLAW_SERVICE_ROOTS` F 盘目录和 `BSClaw-Local\services`。仅当目录内存在有效 manifest 和真实入口时注册；目录名、README 或脚本本身都不足以注册服务。

## 必填声明

manifest 必须声明 id、名称、版本、type、入口、动作、风险、业务写入、服务状态写入、外部依赖和禁止直接访问边界。

资源选择也是正式契约的一部分。用户界面只展示资源列表并接收序号：单资源动作使用 `single`，批量动作使用 `multi`，全量检查使用 `all`。选择器把选中的内部 resourceId 注入调度请求，普通用户不输入、不复制该值。当前 PortManager 只声明单资源动作和“全部启用资源”检查，未声明的多选动作不会出现在菜单中。

## PortManager 适配

PortManager 是首个 `resource-service`。统一调度只调用其公共入口：

`PortManager-Phase1\port-manager.ps1 -Action <允许动作> -OutputFormat Json -NonInteractive`

当前由 scheduler 经适配器调度的动作：

- `service-check` → `ServiceCheck`；
- `list-resources` → `List`；
- `resource-detail` → `Detail`；
- `check-resource` → `Check`；
- `storage-plan` → `StoragePlan`。
- `register` → `Register`；`edit` → `Edit`；`enable` → `Enable`；`disable` → `Disable`；`delete` → `Delete`；`check-all` → `CheckAll`；`occupancy` → `Occupancy`；`login-check` → `LoginCheck`；`cancel-login-check` → `CancelLoginCheck`。

`ServiceCheck`、`List`、`Detail` 和 `StoragePlan` 是 `pure-read`，只展示或盘点，不写 PortManager 运行状态。`Check` 是 `service-state-write`：允许更新运行状态、检测时间、临时租约和审计记录，所以 SQLite 文件哈希可能变化；它不改 schema、资源定义、CredentialRef、Profile 或外部业务。

`Register`、`Edit`、`Enable`、`Disable`、`Delete`、`CheckAll`、`Occupancy`、`LoginCheck` 和 `CancelLoginCheck` 已通过 scheduler/适配器接入，并按 `service-state-write` 或 `pure-read` 记录服务状态影响。`CleanCache` 仍不属于本服务插件的自动调度动作。`Open` 与正式 `Login` 保留为需要用户确认和人工输入的公共入口，不在后台任务中自动代替用户操作；普通菜单只能按确认流程进入，不能通过改变 action 文本绕过边界。

## 输出与可插拔性

适配器 stdout 只能输出一个 UTF-8 JSON 对象。返回只保留资源编号、端口、状态、SQLite integrity 和存储汇总；CredentialRef、Profile 路径、浏览器存储及鉴权材料不会进入调度记录。

### Check/Detail 统一结果契约

`Check` 和 `Detail` 对同一资源事实源使用统一的脱敏资源对象。`Check` 的 `result` 必须同时包含：

- `resource`：资源事实和同一组状态字段；
- `connectionStatus`：连接状态；
- `pageStatus`：页面状态；
- `loginStatus`：登录状态；
- `apiStatus`：只读 API 探针状态；
- `confidence`：状态置信度；
- `checkedAt`：最近检查时间；
- `nextAction`：用户下一步建议。

状态字段只能来自 PortManager 公共 JSON 返回的脱敏 `lastStatus`；调度层、任务中心和资源详情不得各自猜测或维护第二套状态事实。适配器必须保留 `resource.lastStatus` 的脱敏兼容形态，同时提供上述直接字段，避免任务结果包装后丢失登录、页面或 API 状态。

其他服务可按相同 manifest 和 stdin/stdout 协议接入，无需修改调度核心。PortManager 仍可独立运行和发布；统一调度层不进入当前端口管理 GitHub 发布边界。

## 启动器归属与发布边界

`bsclaw` / `BS Claw` 启动器属于 `BSClaw-Local` 统一调度本地层。PortManager 目录中的同名历史启动文件只用于本机兼容，不属于 PortManager 发布清单，也不得随端口管理仓库推送。PortManager 发布候选只包含端口管理自身代码、文档、测试、适配契约和零数据模板。

调度任务可以记录 `ResourceId` 以关联资源；它只在内部任务、机器接口和技术信息中使用，不是普通用户的输入项，也不是 CredentialRef 或凭据。任务、结果和审计均禁止保存账号、密码、Cookie、Token、完整授权头或浏览器存储内容。
