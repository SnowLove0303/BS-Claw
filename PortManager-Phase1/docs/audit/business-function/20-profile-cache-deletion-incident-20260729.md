# Profile 可再生缓存误删事件记录（2026-07-29）

## 事件性质

这是一次已经止损的操作边界问题，不是正常优化效果。审计过程执行真实 `Check` 时，旧版浏览器启动链路隐式调用缓存清理函数；当登记 Chrome 需要启动时，函数未经独立确认便删除了真实 `huice-53392` Profile 中被识别为可再生缓存的目录。

## 现象与影响

- 触发条件：资源 Check 发现 Chrome 未运行，进入旧版 Launch 启动路径。
- Profile 总大小由约 3,221,913,910 bytes 降至首次复核约 109,558,614 bytes，约 3.11 GB 可再生 Chrome 缓存被删除。
- Chrome 后续运行已自动重建部分缓存，之后观测到 Profile 总大小约 234 MB；重建值不代表原缓存已恢复。
- 上述大小只记录事件发生时的历史快照，不是稳定容量结论。Chrome 会按执行需要重新生成缓存，后续容量必须用 `Get-PMProfileMetrics` 动态区分总量、可再生缓存与非缓存 Profile 数据。
- 被删除缓存无法按原字节内容原地恢复，只能由 Chrome 和相关组件按需重新生成或下载。

## 已确认未受损

- `Default` 用户数据目录和原登记 Profile 路径仍存在。
- Cookies、Local Storage、Session Storage、Preferences 不属于清理目标，现有登录会话随后通过真实 Check/Login/API 探针验证。
- ResourceId、端口 53392、Profile 指纹、CredentialRef、SQLite 资源定义、登录状态、迁移记录和正式审计证据未被删除。

## 已采取补救与防复发

1. 普通 Open、Check、Login、List 的启动链路不再调用缓存清理。
2. `Invoke-PMProfileCacheCleanup` 默认仅 dry-run，返回计划目录、文件数和大小，不删除数据。
3. 真实执行必须同时满足：Profile 位于登记根目录、Chrome 未使用该 Profile、显式 `-Execute`、精确中文确认文本和 F 盘审计记录路径。
4. 清理目标只允许已分类的可再生缓存目录；Cookies、Local Storage、Session Storage、Preferences、SQLite、资源定义、CredentialRef 和审计证据不是删除目标。
5. 本轮验收只验证 dry-run 与拒绝路径，不执行真实删除。

## 后续架构债

`PortManager.Core.psm1` 仍是约 1770 行的职责聚合模块。后续可按资源服务、状态检测、租约服务和打开执行服务逐步拆分；本轮为降低回归风险，不进行大重构。
