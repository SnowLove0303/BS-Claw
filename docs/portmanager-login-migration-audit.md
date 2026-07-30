# PortManager 与 HuiceLoginAgent 迁入审计

审计时间：2026-07-30

目标分支：`agent/portmanager-login-agent-migration`
基线：`origin/main@655d458626631e293c7ba534d68b152fcb33c4fd`

## 发布范围与架构结论

本次发布冻结为两个同级模块、仓库治理文件、人工验证文档和本审计记录。PortManager 是资源、租约、审计和 `port_runtime_states` 当前状态真源；HuiceLoginAgent 是受控登录适配器，只消费 ResourceId 与一次性内存凭据，执行已有会话复用或同源 HTTP 登录，再把脱敏结果写回 PortManager SQLite 契约。插件、调度器、MCP 和 UI 不接触明文凭据。

`PortManager.Core.psm1` 当前 1614 行，与迁入来源一致。本次没有把仓库发现、登录适配、存储盘点或发布逻辑继续堆入 Core；跨仓发现分别落在 LoginStateDetector、HuiceLoginAdapter、Profile、EnvironmentMaintenance 和 SQLite service 的现有职责模块。Core 后续仍应按资源、检测、打开和租约职责逐步拆分，但不是本次迁入阻断。

## A. 发布与仓库阻断

- A1 通过：`PortManager-Phase1/` 与 `HuiceLoginAgent/` 同仓同级交付。登录适配器优先读取 `BSCLAW_HUICE_LOGIN_AGENT_ROOT`，否则发现同级目录；不依赖来源机器绝对路径。
- A2 通过：`PortManager-Phase1/data/ports.json` 为精确空数组 `[]`；`logs/README.md` 仅说明日志目录。独立克隆静态验证 8/8，空库 PortManager List 成功且资源数 0，中文菜单可安全退出。
- A3 通过：发布文件使用白名单冻结，不使用 `git add -A`。精确文件清单见 `docs/release-file-manifest.md`。
- A4 通过：仓库根和两个模块均有精确忽略规则。`git check-ignore` 已验证测试账号、SQLite/WAL/SHM、runtime、logs、测试运行产物、审计证据、维护审计、备份、IPC、Python cache 和 Profile 被排除；空数据引导与 README 不被忽略。
- A5 通过：本机测试账号文件未复制；发布代码仅支持交互式不回显输入或未来 CredentialRef/受控凭据提供器，不含 Credential 实值。

## B. 功能与回归阻断

- B6 通过：RG-016 和 LS-005 已改为要求鉴权证据规则非空、`autoLoginImplemented=true`、`loginAdapter=HuiceLoginAgent`；旧版本写死断言同步为适配器 `0.4.0`。
- B7 部分自动验证、外部边界明确：业务回归 20/20；登录状态回归 10/10，覆盖未登录分类、真实慧策登录页、状态持久化、鉴权规则、租约归零和敏感扫描。真实 Read-Host 账号密码登录未在发布克隆自动执行，必须由用户按 `docs/manual-validation.md` 输入；验证码、短信、滑块、二维码或二次确认若触发，属于明确外部阻断，不能伪造通过。
- B8 通过：SQLite 的 `login_automation_state` 写入语义改为 `huice-same-origin-http-login`；根入口、内部入口和适配器分别声明 25/25/24 个 Action（适配器不含交互菜单），静态检查确认无缺失或多余。文档统一描述“Read-Host/受控凭据 → 同源 HTTP 登录 → ERP/API 探针 → 状态持久化”。
- B9 通过：迁入测试只使用隔离运行目录和临时资源，不清理、复制或依赖任何本机正式资源、旧 PID、端口占用或 Profile 缓存。
- 审计打回修正：当前设计文档已改为运行契约；静态验证同步检查 1 条启用鉴权规则、`autoLoginImplemented=true`、`loginAdapter=HuiceLoginAgent`、同源 HTTP 实现和文档标记。

## C. 轻量化与最终验收

- C10 通过：来源目录动态盘点为 `tests/runtime` 634,512,030 字节、`data/test-runs` 496,492,512 字节、`runtime` 245,453,378 字节，合计 1,376,457,920 字节；全部是未迁入的可再生测试/运行数据。来源 `_portmanager-profiles` 当前 1,902,779,727 字节，也未迁入。本次未删除来源 Profile、缓存或测试产物。
- C11 通过：Core 迁入前后均为 1614 行；本次新增边界没有写入 Core。现有子模块职责保持不退化。
- C12 通过：已按“敏感扫描 → 静态 8/8 → 业务回归 20/20 与登录状态回归 10/10 → 人工文档 → diff 检查 → 精确暂存”的顺序完成本地发布验证；提交、推送与草稿 PR 信息由 PR 记录提供。

## 验证摘要

- PowerShell：45 个 `.ps1/.psm1` 文件语法解析无错误。
- Node：2 个 JavaScript 文件通过 `node --check`。
- Python：SQLite service 通过 AST 与 `py_compile`。
- 静态验证：8/8；无 Python 配置回归为退出码 2、单行中文提示、stdout 为空、新增运行目录 0。
- 业务回归：20/20；执行了真实端口冲突、真实浏览器失败回收和真实慧策登录页，但未输入真实凭据。
- 登录状态回归：10/10；测试后 Chrome 配置进程 0、活动租约 0。
- 零数据：PortManager List 单一 JSON、资源数 0；SQLite `integrity_check=ok`、schemaVersion 36、活动租约 0。
- `System` 工作树保持干净；现有 PR #1 保持 OPEN/DRAFT 且未修改。

## 不发布内容

数据库、WAL/SHM、端口运行数据、真实资源、Credential 实值、测试账号文件、Profile、浏览器缓存、runtime、日志、测试运行产物、audit-evidence、maintenance-audits、backups、IPC 和 Python cache 均不进入 Git。

## 回滚

迁入分支与 `main` 隔离。合并前可直接关闭新草稿 PR 或删除远端迁入分支；不会修改现有 PR #1。运行数据不在 Git 中，因此回滚源码不会删除用户数据库、Profile 或会话。
