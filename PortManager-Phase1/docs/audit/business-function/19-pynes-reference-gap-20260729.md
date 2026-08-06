# Pynes 参考读取记录

## 只读查找范围

- `F:\XIANGMU\AI dianshang`：仅发现基础配置、平台拆解与技术路径及慧策商品分析发布包，未发现 Pynes 源码、端口管理实现或 Git 仓库。
- `F:\XIANGMU\XIANGMU` 全局文件搜索：未发现 `Pynes-CC`、Pynes 端口管理源码或可用备份。
- `PortManager-Phase1` Git 历史：仅包含 BS Claw PortManager 自身提交，没有 Pynes 实现历史。
- 公开仓库 `SnowLove0303/Pynes-CC`：本轮未取得可读取源码副本。

## 结论

本轮**未能读取 Pynes 实现**，因此不宣称已借鉴其真实代码、字段或流程。当前 BS Claw 实现仅依据本项目审计需求和已有适配器契约：稳定资源绑定、分层状态、SQLite 安全元数据、Profile 复用、进程归属校验和 watcher 收口。

## 待确认边界

若后续取得授权的 Pynes 源码或备份，应先只读提炼其资源身份、登录状态机、Profile 持久化和失败回收，再与本实现做差异审查；不得直接复制业务耦合、数据库字段或登录凭据处理。
