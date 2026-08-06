# 统一选品模块资料包补充记录

- 变更：将前期十类内容统一为 SEL-01 至 SEL-10，并补充完整业务链、实现分层、PowerShell/SQLite 方法、HTTP API 参考、数据契约、审计矩阵和追溯表。
- 参考：用户指定的 Pynes Desktop 仓库（commit `7adc8f4f26d19d1ac386d06ff3c4ed64f16b4ae6`）、Feishu 旺店通 HTTP API 文档、BS Claw 当前资料包与现有模块边界。
- 当前策略：Phase 1 关闭业务人工确认；外部认证和安全门禁仍不可绕过。
- 事实声明：本次只修改选品模块资料包，未实现代码、未连接 HTTP API、未执行真实选品写入、未修改现有模块/数据库/AIstudy。
- 待维护：真实 API 字段、选品条件、规则版本、schema、隔离资源、性能基线和完整真实路径证据。
