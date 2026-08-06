# 选品模块主干开发派发记录

- 接收线程：技术执行开发线程 `019fbc08-5930-7742-b338-0ae8b97f7073`
- 目标仓库：`F:\XIANGMU\BS Claw\SelectionModule-Phase1`
- 分支：`feature/selection-module-phase1`
- 任务性质：独立选品模块 Phase 1 主干开发；不把选品代码混入 BSClaw-Local 或 PortManager-Phase1。
- 资料基线：本目录 `manifest.json` schema v2、`docs/unified-selection-spec.md`、`docs/implementation-method.md`、`docs/data-and-contracts.md`、`docs/http-api-reference.md`、`docs/audit-and-test-matrix.md`。
- 当前策略：业务人工确认关闭；自动预检通过后自动执行。登录、权限、验证码、风控和资源事实门禁不可绕过。
- 本轮必须完成：独立 PowerShell + SQLite 骨架、manifest/adapter、调度公开契约、资源预检契约、候选只读链、状态/审计/恢复骨架和代码级交接。
- 本轮不得假定完成：正式选品条件、生产写入、发布流程、未经真实响应核验的字段映射。
- 交付门禁：技术线程只提交逐项实现与自检证据；需求与审计线程后续独立执行一至四级审计，不得以代码自检代替业务通过。
