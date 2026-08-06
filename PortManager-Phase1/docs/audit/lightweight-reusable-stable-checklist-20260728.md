# PortManager-Phase1 轻量化 / 可复用 / 稳定性核对表

日期：2026-07-28  
基线：`f5663db`（本轮未提交）  
上游规范：AIstudy 连接器当前线程不可用，已按线程中转的 BS Claw 轻量化、可复用、稳定约束执行；缺口已记录，不宣称已完成 AIstudy MCP 复核。

## 1. 轻量化

| 项目 | 当前证据 / 约束 | 结论 |
|---|---|---|
| 源码目录大小 | 约 866,026,324 bytes；包含历史测试运行产物 | 需清理历史产物；本轮不删除用户数据 |
| 旧项目内运行目录 | `PortManager-Phase1\runtime` 约 245,453,378 bytes，主要为既有 Chrome Profile | 保留作为历史/用户运行数据，禁止在浏览器运行期间搬移或删除 |
| 当前 JSON 运行根 | `F:\XIANGMU\BS Claw\PortManager-Phase1\data` | 按最新阶段边界统一资源、状态、租约、审计和测试记录 |
| 临时 Profile 根 | `F:\XIANGMU\BS Claw\_portmanager-profiles` | 与源码和正式 data 物理分离 |
| Profile | 仅允许 F 盘；新 Launch 使用独立运行根下 `browser-profiles` | 通过路径校验 |
| 缓存回收 | 仅清理 `Cache`、`Code Cache`、`GPUCache`、`Safe Browsing` 等缓存目录 | 不删除 Cookies、Local Storage、Session Storage、Preferences |
| 单 Profile 监控 | `lastStatus.profileMetrics` 保存文件数、总大小、缓存大小 | 仅保留元数据；后续可配置上限和告警 |
| 测试 Profile | 回归脚本使用唯一 F 盘临时运行根；真实 Chrome 进程结束后才可回收 | 用户环境测试不得自动删除用户 Profile |

## 2. 可复用

- 入口、核心服务、状态模型、检测器、Chrome 生命周期、Profile 策略、持久化和适配器分模块；插件只使用资源编号，不写死端口或 Profile 路径。
- `LoginStateDetector` 只消费端口资源契约；慧策页面规则和鉴权规则来自 adapter。当前没有可靠真实鉴权探针时只返回“登录状态未知”。
- Text/JSON 共用 `PortManager.Core`；JSON 错误包含 `errorCode`、`nextAction`，不混入提示文本。
- 登录状态只保存证据摘要、时间、来源、状态和探针元数据，不保存密码、Cookie 值、Token 或完整授权头。

## 3. 稳定

- 注册最终写入、编辑、删除均在写锁内再次检查端口、资源和占用。
- 检测器使用每资源状态文件 + 命名互斥 + 子进程 single-flight；支持异步启动、取消、超时记录和重启后状态回读。
- 端口、浏览器、页面和登录状态分层；CDP 可达不能推出已登录。
- 失败状态回写 `ports.json`；检测器记录写入 `login-detections.json`，均在 F 盘并受敏感字段扫描保护。
- Open 失败回收本次启动 Chrome 和租约；高风险真实业务调用在登录状态未知/失败时仍需上层阻断。

## 4. 本轮验证与缺口

- 已验证：PowerShell 解析、隔离空库注册、异步 LoginCheck、检测完成后状态持久化、检测记录和 F 盘日志路径。
- 未验证：真实慧策鉴权成功证据、Cookie/Local Storage 复用、用户真实 Profile 迁移、Profile 损坏恢复、长期 10 分钟调度和系统重启后的自动恢复。
- 证据根目录：`F:\XIANGMU\BS Claw\PortManager-Phase1\data\audit-evidence`；每次回归应生成 `summary.json`、`failure.md`、`evidence-index.md`。

## 5. 回滚

## 6. SQLite 复核补充

- SQLite 文件：`data\port-manager.sqlite3`；Python 驱动为 E 盘现有 Anaconda 的标准库 `sqlite3`，未安装额外第三方依赖。
- 当前迁移：schema 版本 13；表包括资源配置、运行状态、登录检测历史、租约、审计和删除历史归档；WAL、外键和 busy timeout 已在真实空库/迁移库中验证。
- JSON 角色：`ports.json` 只作为迁移输入和回滚备份；运行时不再写入 `ports.json` 或 `leases.json`。
- 迁移证据：每个隔离运行目录的 `data\migrations\pre-sqlite-baseline.json`、`ports.migration-*.json` 和 SQLite 查询结果均保留在 F 盘。
- 尚未验证：真实慧策鉴权成功证据、Cookie/Local Storage 登录复用、系统重启后的自动调度；这些不能用静态或假数据宣称通过。

本轮无提交。回滚点为 `f5663db`；恢复代码时只需丢弃本轮未提交变更，运行数据保留在 F 盘。旧项目内 `runtime` 不在本轮删除范围，避免破坏仍在使用的 Chrome 会话。
