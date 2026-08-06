# 正式 data 目录 SQLite 收口烟测

证据目录：`data\audit-evidence\formal-smoke-20260728-1955`。

本次以 `data\port-manager.sqlite3` 作为唯一运行时来源执行正式入口。注册、List、Detail、Edit、Check、CheckAll、Open、Delete 均已实际调用；三个临时资源均为真实本机端口配置，探测结果为“不可连接/登录状态未知”，没有使用 mock 或假登录。

Open 真实失败退出码为 1，结构化错误码为 `PM_BROWSER_NOT_AVAILABLE`；失败状态写回 SQLite，租约最终为 0。注册 `HCP-542A576E` 后由新 PowerShell 进程执行 List/Detail 仍可读取，证明重启恢复来自 SQLite；删除后资源表为 0，删除快照历史为 3 条。

真实 Chrome CDP、慧策页面匹配和登录鉴权证据因测试端口不可达未验证，不能宣称通过。完整中文向导回归此前按超时策略中止，失败摘要见 `data\audit-evidence\business-regression-20260728-192252-b014a724ef164051b950bdd4d6d9ae5c`。
