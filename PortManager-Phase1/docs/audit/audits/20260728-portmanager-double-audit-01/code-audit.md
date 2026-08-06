# 代码审计结果

## 已核对范围

已读取项目规则、入口脚本、Core、Huice、Chrome、Login、Persistence、State、Output、Registration 模块，适配清单、执行规范、风险说明和既有回归记录；并执行 PowerShell 原生语法解析、JSON 解析、空库启动和隔离运行检查。

## 通过项

1. 20 个 `.ps1/.psm1` 脚本可被 PowerShell 5.1 解析。
2. 适配清单和端口数据 JSON 可解析，运行数据默认落在 F 盘 `runtime`，支持 `BSCLAW_PM_RUNTIME_ROOT` 隔离。
3. Chrome 启动路径限制为真实 `chrome.exe`，Edge 不作为回退；浏览器配置目录限制在 F 盘。
4. 不保存密码、Cookie、Token、完整授权头；资源只保存 Credential Ref 预留字段。
5. Edit/Delete/Open 具备租约与活动监听占用保护，写入操作在写锁内复核；删除要求精确中文确认并写审计。
6. Open 失败路径会持久化“打开失败”、错误摘要并尝试回收本次启动的 Chrome；租约在 finally 中释放。
7. 登录检测在没有已启用鉴权证据规则时保持“登录状态未知”，没有把页面、端口或历史状态冒充为已登录。

## 代码问题与风险

### CA-P1-001 注册端口冲突检查不在写锁内完成

位置：`scripts/lib/PortManager.Core.psm1` 的 `Register-PMResource`。

现象：注册先在写锁外执行 TCP、端口所有者和 CDP 检测，进入写锁后只复核重复资源，不重新复核端口监听状态。检测完成到保存之间若其他进程占用端口，资源仍可能被写入。

影响：注册后的端口资源可能立即进入端口冲突，破坏“注册即建立可管理真实资源”的一致性；并发场景下会出现先检查通过、保存时已被占用的竞态。

建议交给开发线程：在同一写锁内重新读取资源并复核端口所有者、CDP 身份和必要的连接状态；保留外层快速检查作为提示，但最终判定必须以锁内结果为准。

### CA-P1-002 已登录状态仍无法形成正向鉴权证据

位置：`scripts/lib/PortManager.Login.psm1`、`adapter/bsclaw-port-adapter.json`。

现象：`authenticatedEvidenceRules` 为空，解析器在慧策页面正确且非登录页时仍返回“登录状态未知”。

影响：当前可以可靠识别登录页和“未知”，但无法完成“已登录”门禁；后续 HTTP 插件不能据此安全进入需要登录的业务流程。自动登录、Credential Ref 后端、会话复用和登录失效闭环也尚未验证。

判定：这是当前阶段的能力缺口，不得作为已完成登录检测闭环。

### CA-P2-003 检测全机监听端口带来噪声和额外开销

位置：`scripts/lib/PortManager.Huice.psm1` 的 `Get-PMChromeDebugEndpoints`、`PortManager.Core.psm1` 的 TCP 回退日志。

现象：扫描全部监听端口并逐个探测 `/json/version`；`Get-NetTCPConnection` 异常时反复记录 WARN，再回退 `netstat`。

影响：首次注册和菜单操作可能变慢，日志被大量无匹配端口 WARN 淹没，真实故障不易定位。

### CA-P2-004 历史审计文档与当前 Chrome-only 代码基线不一致

位置：`docs/audit/audits/20260728-portmanager-hot-run-01/`。

现象：历史热试车报告仍描述 Edge Launch，而当前代码和执行规范已明确 Chrome-only。

影响：人事部、开发线程或后续审计读取历史资料时可能误判浏览器策略和验收结论。

### CA-P2-005 错误下一步匹配顺序导致占用错误被误判为 Chrome 安装问题

位置：`scripts/lib/PortManager.Huice.psm1` 的 `Get-PMErrorNextAction`。

现象：占用错误消息包含 `chrome(PID ...)`，函数先命中 `Chrome|chrome.exe` 分支，返回“确认已安装 Google Chrome”，没有命中端口占用处理。

影响：真实活动监听、租约和写操作拒绝时，用户得到错误修复方向；这是业务流程反馈缺陷，不影响底层拒绝动作本身。

建议：按错误类型优先级先处理活动监听、租约、端口冲突，再处理浏览器缺失；最好使用结构化 errorType，不依赖自然语言关键词。

## 未验证项

真实已登录慧策页面、正向鉴权证据、登录失效、自动登录、Credential Ref 注入、会话复用、真实 API 调用和 BSClaw 调度接入均未验证。不能以当前静态回归结论替代这些验证。
