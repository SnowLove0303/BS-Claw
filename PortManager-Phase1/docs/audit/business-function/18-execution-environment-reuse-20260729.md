# 执行环境复用与登录同步本轮证据

## 实际资源

- resourceId：`HCP-51DFE5AE`
- host/port：`127.0.0.1:49841`
- Chrome PID：`23368`
- Profile：`F:\XIANGMU\BS Claw\_portmanager-profiles\huice-49841`
- Profile fingerprint：`96fa3d018d9668cc`（仅路径摘要）
- 页面标题：`旺店通 | 慧策`
- 登录状态：`登录状态未知`；适配器 `authenticatedEvidenceRules` 为空，未读取 Cookie/Token。

## 已执行

1. ConnectOnly 注册从真实 CDP 端口发现并持久化 Chrome 路径、Profile、PID、进程启动时间和 Profile 摘要。
2. 跨进程 Check/Detail 从 SQLite 回读绑定；`PRAGMA integrity_check=ok`，schemaVersion=25。
3. Open 两次均复用 PID 23368 和同一 Profile；第二次未重新分配端口或创建新 Profile，退出码 0。
4. Open 后独立 watcher 进程启动；后台 `Test-PMResource` 周期性回写 SQLite，未依赖下一条 CLI 指令。删除资源前会停止 watcher。
5. 静态门禁 7/7 通过；敏感扫描无命中。

## 未验证/下一步

- 没有真实鉴权规则，因此不能验证“已登录”、登录失效或会话复用后的鉴权证据。
- 活动会话在登记前的“已有会话未登记”提示需在隔离端口上重新复测；当前现场会话已登记为 HCP-51DFE5AE。
- 关闭 Chrome 后用同一 Profile、同一端口 Launch 恢复，以及不同 resourceId 隔离，仍需用户真实环境复测。
