# BS Claw 技术验证附录

本文件供开发和审计使用，不是普通用户测试步骤。普通用户只需按 `docs/manual-test.md` 的 `bsclaw` 菜单流程操作。

## 技术入口

开发/审计人员可在已准备好 F 盘 Python 的环境中使用正式 launcher 执行 status、service、task 的 JSON 接口。输出中的 taskId、moduleId、action 和 JSON 仅用于诊断，不要求普通用户复制或理解。

## 后台检测证据

- 启动后初始阶段：`status=running`、`alive=true`，可能暂时没有 heartbeat，表示首轮检查尚未完成。
- 首轮完成后：`status=running`、`alive=true`、`stale=false`、heartbeatAt 有值、resources 包含实际资源结果。
- 正常停止：`status=stopped`、`alive=false`。
- 进程异常退出：下一次状态读取应转为 failed 或 stopped-or-stale，并显示诊断路径。

## 数据边界

状态检查会写入服务运行状态、检测时间、租约和审计记录；不修改 schema、资源定义、凭据、Profile 或外部业务数据。技术回归不得把 SQLite 哈希不变当作服务状态检查不写入的证明。
\n+## 隔离生命周期审计\n+\n+隔离测试必须把 `BSCLAW_PM_RUNTIME_ROOT` 和 `BSCLAW_DATA_ROOT` 指向 F 盘的独立目录，并设置 `BSCLAW_LOCAL_ROOT` 为本地层代码目录。使用 `ConnectOnly` 测试资源，不设置浏览器 Profile，不读取或写入凭据。测试前备份隔离目录；删除、回滚只允许作用于该隔离目录。正式 PortManager 运行根、正式 SQLite、Profile 和登录态保持只读。\n
