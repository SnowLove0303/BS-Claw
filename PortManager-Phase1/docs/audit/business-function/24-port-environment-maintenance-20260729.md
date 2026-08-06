# 端口环境维护功能记录（2026-07-29）

## 目标

将底层缓存识别能力收口为可供用户和后续部署脚本稳定调用的正式功能，并严格区分缓存瘦身、登录重测和迁移准备。

## 状态契约

- CachePlan：只读预览；允许追加审计，但不删除文件、不修改资源定义或登录状态。
- CleanCache：只删除受控 Profile 根目录内已分类的可再生缓存；运行中拒绝；使用操作租约；完成后只刷新 profileMetrics。
- CreateLoginTestProfile：创建独立 ResourceId、端口和空白 Profile；可复用 CredentialRef 引用和脱敏摘要，不复制密码、Token、Cookie 或浏览器会话；初始状态为未登录。
- DeploymentCleanPlan：只输出事实源、可再生数据和迁移后重建清单。
- ResetLoginPlan：只输出风险说明；本阶段不删除正式资源认证状态。

## 事实源与保护边界

不可由普通清理删除：port_resources、schema_migrations、credential_profiles、audit_records、login_session_events、资源定义、CredentialRef、脱敏账号摘要，以及用于登录复用的非缓存 Profile 数据。

CleanCache 不修改 loginStatus、loginApiProbeStatus 或 loginConfidence。旧 login_sessions 仍为单向兼容投影，不能反向覆盖 port_runtime_states。

## 实际验证

- PowerShell 5.1：29 个脚本解析无错误；项目静态验证 7/7。
- CachePlan：正式资源 HCP-E1880AE9 返回成功 dry-run JSON，识别运行中的 Profile，未删除文件。
- CleanCache 运行中拒绝：返回 PM_PROFILE_IN_USE；同一次命令前后正式 Profile 字节数均为 3,145,501,178，变化为 0。
- 隔离真实清理：F 盘隔离 Profile 从 4,218 字节降至 122 字节，删除 4,096 字节、2 个缓存目录；Cookies、Preferences、Local Storage、IndexedDB 四类保护项均保留。
- 隔离数据库回读：profileMetrics 为 sizeBytes=122、fileCount=4、cacheBytes=0；清理租约最终为 0。
- 独立登录测试资源：隔离运行库创建成功，获得独立 ResourceId、53493 端口和空白 Profile；状态为未登录 / login-required / none。
- 中文菜单：输入 9 可进入五项环境维护菜单，输入 0 可返回并安全退出。
- 回归：HuiceLoginAgent Check 为 logged-in-api-ready；PortManager Check/List 为已登录 / logged-in-api-ready / high。
- 数据库：integrity_check=ok，schemaVersion=36；正式库活动租约为 0；System 工作树保持干净。

## 验证中发现并修复的问题

第一次隔离创建登录测试资源时，旧状态对象缺少 lastAuthenticatedAt 属性，导致登记后状态补写失败。失败发生在隔离运行库，不影响正式资源。已改为兼容添加缺失字段，并增加“登记后任一步失败即自动删除本次新资源”的事务补偿；隔离半成品资源已按审计流程删除，随后重测成功。

## 回滚

本轮修改前文件与 SQLite 在线备份位于：

`F:\XIANGMU\BS Claw\_audit-backups\20260729-211414-port-environment-cleanup`

恢复代码时只覆盖本轮备份中已有文件，并删除本轮新增的 `PortManager.EnvironmentMaintenance.psm1` 与本记录；恢复数据库前必须停止 PortManager、LoginAgent、Watcher，并再次备份当前数据库。
