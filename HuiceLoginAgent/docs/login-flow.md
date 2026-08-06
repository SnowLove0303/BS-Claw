# HuiceLoginAgent 登录流程

1. 通过 PortManager 权威 SQLite 解析已登记的 `resourceId`。
2. 校验回环主机、CDP 端口、Chrome PID 与登记 Profile 完全一致。
3. 若 ERP 会话已可用，直接复用并执行只读 API 探针。
4. 若停在产品选择页，自动进入“旺店通ERP3.0”，不要求输入账号密码。
5. 只有确认处于真实未登录状态时，才在 PowerShell 安全读取企业账号、用户账号和不回显密码。
6. 输入完成后，在同一 Profile 的 `login.huice.com` 页面上下文中按慧策官网契约依次调用风险键接口和账号密码接口；CDP 只承载同源 HTTP 调用与 Cookie 会话绑定，不填写或点击 Chrome 登录表单。
7. 常规账号密码路径不需要用户在 Chrome 再次输入或点击。验证码、短信、滑块、二维码或二次确认会返回明确错误码；未实现对应挑战续接时必须失败，不会伪装成成功。
8. 登录成功后执行 auth refresh 与 goods overview 只读探针；两者都成功才返回 `logged-in-api-ready`。
9. 当前状态写入 `port_runtime_states`，脱敏历史写入 `login_session_events`；旧数据库中的 `login_sessions` 只接收单向兼容投影，所有操作使用统一 `resource_leases`。

程序不创建第二套 Profile，不复制浏览器数据；端口或 Profile 不匹配时拒绝复用。

正式运行由 PortManager 先按 CredentialRef/脱敏安全匹配键查找同账号健康资源，并实时 Check 与检查租约；可复用时不读取凭据。仅无健康资源时，PortManager 才通过受控内存凭据提供器向 LoginAgent 提供一次性凭据。插件、调度器和 MCP 只接收最终 ResourceId。

最终用户主验收必须运行真实 PowerShell 交互命令，通过 `Read-Host` 逐项输入并确认协议。`Console.IsInputRedirected` 对应独立的受控传输兼容分支，不是用户主验收入口；该分支的验证码或错误结果不能覆盖 `Read-Host` 路径的真实结论。
