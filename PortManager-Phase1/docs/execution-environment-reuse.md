# 执行环境复用与登录同步

运行时数据库为模块根目录 `data/port-manager.sqlite3`，当前 schemaVersion 为 36。SQLite 是资源定义、运行状态、租约、登录事件和审计的事实源；空 `ports.json` 只用于零数据引导。

每个资源通过 ResourceId、host/port、connectionMode、Chrome 路径和 browserProfileDirectory 绑定稳定执行环境。Open 优先复用登记的端口、Profile 和 Chrome；复用前校验 PID、进程启动时间、调试端口、Profile 与 CDP 页面，不能只相信旧数据库状态。

HuiceLoginAgent 先用实时鉴权续接和只读 API 探针复用健康会话。真实未登录时才读取受控凭据并执行同源 HTTP 登录。成功后写回 `port_runtime_states`，兼容表只能由当前状态单向投影。

Watcher 是可选异步维护进程，不是登录事实源。PID、启动时间或进程身份不匹配时必须标记失活；插件执行前仍需按需 Check。异常退出、超时或外部终止后的死亡租约在下一次调用前自动回收并写脱敏审计。

迁移到新机器时保留代码、schema、资源定义、CredentialRef 与需要复用登录态的非缓存 Profile 数据；PID、Watcher、旧租约、探针结果和 Chrome 缓存均重新发现或重建。
