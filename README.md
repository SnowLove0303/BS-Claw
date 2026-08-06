# BS Claw 选品模块 Phase 1

这是 BS Claw 选品执行模块的独立资料包与开发边界目录，不是当前已实现的业务模块。

## 当前阶段决策

- 运行目标：在统一调度层完成前置匹配后，自动执行选品主干，不设置业务人工确认节点。
- 语言与持久化：沿用 PortManager 的 PowerShell + SQLite + JSON manifest 架构。
- 模块边界：选品模块只负责选品业务动作；端口、Profile、租约、登录态、任务状态和资源事实仍由既有服务提供。
- 自动化限制：自动化不等于绕过登录、安全门禁或凭据保护。若外部登录/验证码/风控未满足，任务必须安全阻断并记录原因，不得伪造成功。
- 当前范围：先建立可运行主干和契约；选品条件、排序策略、供应商规则、写入动作细则和执行规范作为后续补齐项。

## 目录

- `manifest.json`：资料包元数据与当前状态。
- `docs/requirements-baseline.md`：用户目标、功能清单和验收基线。
- `docs/business-chain.md`：从任务进入到业务结果回查的标准链路。
- `docs/architecture-and-boundaries.md`：调度层、PortManager、登录代理和选品模块职责边界。
- `docs/implementation-backlog.md`：主干开发任务清单，当前仅为规划，不代表已实现。
- `docs/acceptance-gates.md`：全自动执行的安全门禁、结果和回归要求。
- `docs/known-gaps-and-deferred.md`：资料缺口、待补规则和不可提前假定的内容。
- `docs/unified-selection-spec.md`：SEL-01 至 SEL-10 统一正式需求、逻辑和业务链。
- `docs/implementation-method.md`：具体实现分层、顺序和 PowerShell 开发方法。
- `docs/http-api-reference.md`：Feishu/Pynes 参考 API 索引与固化要求。
- `docs/data-and-contracts.md`：SQLite、Action、任务和错误契约。
- `docs/audit-and-test-matrix.md`：一至四级审计和真实测试矩阵。
- `docs/traceability.md`：需求、实现、证据和状态追溯。
- `docs/source-index.md`：现有源码、资料包、Pynes 参考仓库与 Feishu 文档索引。
- `changes/selection-pack-initial-20260802.md`：本资料包建立记录。

## 当前状态

资料包已建立；选品业务代码、真实 HTTP API 接通、真实业务结果验证和正式发布均未完成。
