# 数据目录

仓库只保留空引导文件 `ports.json`，内容为 `[]`。首次运行会在本目录创建 schemaVersion 36 的 SQLite 运行库及必要的 WAL/SHM、审计和迁移文件；这些运行数据均被 Git 忽略。

PortManager SQLite 是资源、租约、审计和当前状态真源。不得在本目录保存密码、Token、Cookie、完整授权头或 Credential 实值。
