# 2026-07-29 打回项收口记录

本轮只处理 PortManager-Phase1 的 SQLite/登录检测生命周期与可验证性问题；未接入 `BS Claw\System`，未开发插件、UI、统一调度或登录自动化。SQLite 文件仍为 `data\port-manager.sqlite3`，旧 JSON 仅作迁移/备份输入。

## 已修复

1. 检测任务统一使用内部状态 `running/completed/failed/cancelled`。`set_detection_process` 在 `state=running` 条件下写入真实 worker PID，并在回读不一致时终止 worker；检测 JSON envelope 返回 `attemptId/taskId`。
2. 删除、编辑、打开会检查 SQLite 中活动检测任务；检测中删除返回 `PM_LOGIN_DETECTION_ACTIVE`。取消会先终止并等待真实进程退出，再收口任务；取消后的下一次检测至少延迟 60 秒。
3. 增加超时 reaper。每次 CLI 操作先回收已过期 worker，更新任务、运行状态、下一次重试时间和 SQLite 审计。
4. schema migration 从 15 增至 18：补充 `port_runtime_states.login_detection_started_at`，并在 `deleted_resource_history` 归档登录检测任务与租约快照。启动校验 migration checksum，不一致停止写入。
5. 旧 `leases.json`/`login-detections.json` 元数据迁移不再静默吞解析异常；中文/英文任务状态归一化，marker 只在数据库事务提交后写入，错误摘要统一脱敏。
6. SQLite 审计改为唯一权威写入；JSONL 仅作为 best-effort 导出，数据库写入失败时不再声称审计成功。
7. Python 解释器候选必须通过 F 盘校验；适配器中的运行目录改为相对路径/环境变量。中文菜单移除会阻塞重定向输入的 `Peek()`，静态菜单回归增加 15 秒硬超时和回收。

## 实际验证

- F 盘 Python：`F:\AIAPP\Codex\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`。
- `List -OutputFormat Json`：正式 `data\port-manager.sqlite3` 可打开，schemaVersion=18，退出码 0。
- 异步检测 PID：隔离目录 `data\test-runs\pid-check-20260729`，真实 worker PID `23288` 写入 SQLite，任务初始为 `running`；未连接端口最终为未知登录状态，未伪造已登录。
- 检测中删除保护：隔离目录 `data\test-runs\delete-active-20260729`，真实 worker PID `24908`，删除返回“资源正在进行登录状态检测”并拒绝；取消后进程收口，随后删除可执行。
- 超时 reaper：隔离目录 `data\test-runs\reaper-20260729`，1 秒超时任务被真实回收，详情显示 `LOGIN_DETECTION_TIMEOUT`、60 秒后重试和 `bsclaw.login-state-detector.reaper` 来源。
- 迁移/归档/校验与 PowerShell/Python 静态检查继续使用独立 F 盘证据目录；真实慧策页面、CDP 成功打开和真实鉴权证据本轮仍未验证。

## 未验证与回滚

真实 Google Chrome 慧策页面匹配、已登录鉴权证据、会话复用、Launch 成功路径需用户环境复测，不能用未连接端口结果替代。回滚使用开发前 Git 基线 `f5663dbc3d53d7dcf037ba1afe600452c6d88e97`，并保留 `data\migrations\pre-sqlite-baseline.json` 与旧 JSON；本轮未提交、未推送。
