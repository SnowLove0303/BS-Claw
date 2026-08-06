# BS Claw 端口管理推广收口证据

时间：2026-07-29 22:40–23:14（Asia/Shanghai）

## 结论

PortManager Phase1 已达到“后续插件/调度只读资源获取、执行前 Check、会话复用、租约与审计”的受控推广基线。不得把当前含运行数据的整个目录原样分发，也不得据此宣称“重新输入真实账号密码的完整 Login”已由开发代替用户验收。

## 本轮收口

1. 根 `port-manager.ps1` 成为唯一推荐入口，与内部入口均支持 25 个正式 Action。
2. HuiceLoginAgent 作为受控登录适配器；PortManager/SQLite `port_runtime_states` 仍是资源和当前状态真源。
3. Huice 与 PortManager 均改为环境变量或相邻目录发现，移除散落的绝对模块耦合。
4. `PortManager.Core.psm1` 从 1775 行降至 1613 行；网络原语迁入 `PortManager.Network.psm1`，耗时跟踪迁入 `PortManager.Performance.psm1`。体积审计和慧策登录边界均为独立模块，没有继续堆进 Core。
5. Open/Check/LoginCheck 输出阶段耗时。已运行资源 Open 从审计基线约 50 秒降至实测约 19 秒；Chrome 复用阶段约 3 毫秒。
6. 修复异步 LoginCheck 使用弱证据覆盖 `logged-in-api-ready` 的回归：慧策异步检测现在调用真实 HuiceLoginAgent Check。
7. 修复异步 worker 标准句柄导致 LoginCheck 表面同步等待；启动实测约 5.8 秒，随后后台收口。
8. StorageAudit 对代码、数据库、日志、测试产物、运行数据和全部 Profile 分层盘点，全程 dry-run。

## 当前动态基线

- 代码：607,210 bytes。
- SQLite/迁移事实源：1,539,726 bytes。
- 日志：22,655 bytes。
- 测试产物：1,047,025,335 bytes，其中 `tests\runtime` 约 634.5 MB、`data\test-runs` 约 412.4 MB。
- 可再生运行目录：245,453,378 bytes，主要为 `runtime\browser-profiles`。
- 全部 Profile：4,101,964,433 bytes；可再生缓存 3,803,919,483 bytes；非缓存数据 298,044,950 bytes。
- `huice-53392\OptGuideOnDeviceModel`：2,862,922,939 bytes，属于可再生 Chrome 运行数据。

这些是动态盘点值，不是写死容量承诺。普通 List/Check/Open/Login 不会清理；正式 Profile 本轮只读，CachePlan/DeploymentCleanPlan 前后字节数一致。

## 真实验证

- 静态验证：8/8；PowerShell 33 个脚本解析、JSON、F 盘 Python 编译、空库启动、中文菜单、根入口 Action 对齐、交付路径、System 基线全部通过。
- HCP-E1880AE9：`已登录 / high / logged-in-api-ready`。
- Huice：auth refresh HTTP 200；只读 probe HTTP 200；必要字段存在。
- 浏览器：主 PID 23824，53392，登记 Profile 不变；11 个相关 Chrome 进程，工作集约 1.17 GB。
- Watcher：PID 21872，进程与数据库启动身份匹配，工作集约 90.9 MB；心跳与 nextCheck 实时更新。
- SQLite：integrity `ok`，schemaVersion 36，最终活动租约 0。
- `port_runtime_states` 与 `login_sessions` 单向兼容投影均为 `logged-in-api-ready`。
- LoginCheck：后台任务完成后仍保持真实 Huice 证据，Occupancy 无残留任务。
- CachePlan 与 DeploymentCleanPlan：成功、dry-run、未删除；StorageAudit 输出 12 个 Profile 和 Top 膨胀项。
- `F:\XIANGMU\BS Claw\System`：工作树干净。

## 性能证据

- List：约 5.3 秒。
- Detail：约 4.2 秒。
- HuiceCheck：约 3.0–5.4 秒。
- Check：约 14–19 秒；阶段证据显示主要成本为 SQLite 资源读取/租约写入释放，真实 CDP/Profile 探针约 2–3.2 秒。
- Open 复用：约 18.9 秒；浏览器复用 3 毫秒，页面复用 13 毫秒，主要成本仍为 SQLite 与双次真实回查。
- LoginCheck 入队：修复后约 5.8 秒；后台实际 Check 另行收口。
- StorageAudit：约 20.8 秒；DeploymentCleanPlan（含全量盘点）：约 25 秒。

## 推广边界

可推广：资源/状态查询、List/Detail/Check/Open/Occupancy、租约、异步 LoginCheck、HuiceCheck、缓存/部署 dry-run、机器 JSON 信封。

仍需用户验收：在独立登录测试资源中重新输入企业账号、用户账号和不回显密码的完整 Login，以及验证码/滑块等真实安全验证分支。高风险写入插件、完整调度器、UI、打包发布不在本阶段。

原始目录因测试产物和 Profile 过大被 StorageAudit 标记为“不可原样推广”。推广时冻结源码、schema、迁移、正式文档和必要事实源；排除测试产物、运行数据、缓存、日志、PID、Watcher 和过期租约。

## 回滚

修改前备份：

`F:\XIANGMU\BS Claw\_audit-backups\20260729-224055-promotion-closure`

SQLite 在线备份及本轮涉及文件均在该目录；备份 SHA256：

`94F7EDB8C8E274F7F0303034BD51ECF0F1BDCF156BF80D8B82C956B1F0F17B37`

回滚时先停止相关 PortManager/HuiceLoginAgent 操作，逐文件恢复；数据库只有在确认需要回滚且再次备份当前库后才允许恢复，并必须复验 integrity、schema、资源状态和租约。