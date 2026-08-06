# BS Claw 本地调度层架构

## 稳定边界

`BSClaw-Local` 是用户入口与统一调度壳。PortManager 仍是独立资源服务，统一层只通过服务 manifest、公开 PowerShell JSON 入口和插件进程协议调用它；统一层不导入 PortManager PSM1，也不直接读写 PortManager SQLite。

普通用户从 `bsclaw` 中文菜单操作。`status/modules/service/task --json` 是兼容的开发与审计接口，不是普通用户完成操作的必要步骤。

## 启动入口与发布边界

正式入口归属 `BSClaw-Local`，由本目录的 `install-bsclaw-command.ps1` 将 `tools\command-launcher` 放到用户 PATH 首位。安装时会从 PATH 移除 PortManager 目录中的旧兼容入口，但不会删除兼容文件。

PortManager 中的 launcher 仅负责兼容转发，不属于统一调度层的正式发布入口。统一层通过服务说明文件、适配器进程和 PortManager 公开 JSON 命令调用资源服务；不复制 PortManager 源码、不导入其内部模块、不直接访问其 SQLite。

迁移到新路径时，应保持 `BSClaw-Local` 与 `PortManager-Phase1` 为同级独立模块，在新路径重新运行入口安装脚本。运行记录、任务日志、Python 运行时、SQLite、Profile、缓存、PID、Watcher 和租约不属于可复用发布基线。

## CLI 分区

- `cli.py`：控制台编码、应用装配、顶层命令路由。
- `cli_parser.py`：argparse 命令和参数声明。
- `app_context.py`：本地适配器装配、状态/诊断/审计查询用例。
- `cli_handlers.py`：task/service 开发接口处理与同步等待。
- `cli_output.py`：中文与 JSON 输出。
- `parameter_loader.py`：F 盘参数文件、内联 JSON 和安全解析。
- `user_interface.py`：普通用户菜单路由；资源、服务、任务页面分别位于独立 console 模块。

旧 `cli.py` 中的 `build_parser`、参数解析、task/service 处理、输出、`LocalApplication` 已分别迁移到上述单一职责文件。`cli.LocalApplication` 仍作为兼容导出，后台 worker 与既有调用方无需改变。

## 调度分区

- `scheduler.py`：稳定的 `submit/status/result/list/cancel/retry/recover/run_worker` 门面。
- `scheduler_preflight.py`：manifest、入口、动作、写入等级、登录门禁和资源策略预检。
- `scheduler_execution.py`：worker 派发、插件执行、超时/取消协作及执行结果分流。
- `scheduler_verification.py`：插件回查与已生成结果的契约校验。
- `scheduler_recovery.py`：取消、重试、重启恢复和进程存活检查。
- `scheduler_failures.py`：统一预检阻断结果。
- `scheduler_view.py`：插件输入与脱敏公开任务投影。
- `scheduler_store.py`：调度事实持久化与状态迁移。

拆分保持原任务状态、JSON 字段和 worker 入口不变。组件通过明确构造参数协作，不访问彼此内部文件，也不复制状态机判断。

## 写入边界

- `pure-read`：不写服务状态或外部业务。
- `service-state-write`：允许 PortManager 更新实时检测状态、临时租约与审计；不改 schema、资源定义、Profile 或外部业务。
- `business-write`：当前统一阻断。

调度自身会在 `data/scheduler` 写任务状态与脱敏审计。这些是可重建的本地运行记录，不是 PortManager 资源事实源。

## 下一阶段结构控制点

`module_registry.py` 当前同时负责搜索目录、读取模块说明、校验注册信息和生成公开状态。接入新的 Python 工作流前，应先拆分为发现根目录、说明文件读取、校验和公开投影四个组件，避免业务模块增加时继续扩大注册核心。本轮没有修改该文件或改变现有注册行为。
# 运行时状态与性能边界

统一层只在同一个菜单进程内复用端口资源列表，缓存窗口为短时会话缓存；缓存命中不改变 PortManager 事实源。缓存失效或用户明确刷新时，统一层通过公开 `port-manager.ps1` 入口重新读取。

资源状态由 PortManager 最近一次真实检查提供。统一层同时输出检查时间与新鲜度：有效窗口内为“实时”，超过窗口为“已过期”，没有检查记录为“从未检测”。过期状态不会被映射为“可用”。资源详情中的“重新检查状态”调用公开 `Check` 动作并允许服务运行状态写入；展示列表、总览和模块发现仍不直接访问 PortManager SQLite、Profile 或内部 PowerShell 模块。
