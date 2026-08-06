# 历史审计快照

本目录保存各轮真实审计证据和当时结论，不是当前运行契约。历史文件中的 schema 版本、内部 `scripts\port-manager.ps1` 命令、未实现能力和瞬时体积只代表生成当时，不得用于新开发判断。

当前入口与契约只以以下文档为准：

- `F:\XIANGMU\BS Claw\PortManager-Phase1\docs\README.md`
- `F:\XIANGMU\BS Claw\PortManager-Phase1\docs\execution.md`
- `F:\XIANGMU\BS Claw\PortManager-Phase1\docs\sqlite-schema-current.md`
- `F:\XIANGMU\BS Claw\PortManager-Phase1\docs\manual-test-promotion.md`

当前机器状态必须通过根入口 List、Check、Occupancy、StorageAudit 和 SQLite integrity 实时读取，不能继承历史快照。

