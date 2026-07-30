# BSClaw 端口资源与登录状态当前契约

## 文档定位

本文描述仓库当前运行契约，以 `adapter/bsclaw-port-adapter.json`、`scripts/sqlite_service.py` 和同级 `HuiceLoginAgent/` 实现为事实来源。早期“只检测登录、鉴权规则为空、自动登录未实现”的方案已经失效，不得作为当前开发或审计依据。

关键值：

- authenticatedEvidenceRules：当前为 1 条启用规则。
- autoLoginImplemented：true。
- loginAdapter：HuiceLoginAgent。
- loginAutomationState：`huice-same-origin-http-login`；这是唯一正式枚举，禁止使用无平台前缀的同义值。
- loginTransport：`same-origin-http` 只表示单次桥接响应采用的传输方式，不是持久化枚举，禁止将其写入 `loginAutomationState`。
- 当前状态真源：SQLite `port_runtime_states`。

## 一、模块边界

PortManager 负责：

- ResourceId、端口、Chrome 可执行文件和 F 盘 Profile 定义。
- 资源租约、进程身份、占用状态和异常租约回收。
- SQLite schema、当前运行状态、登录事件和脱敏审计。
- 在插件、调度器或人工操作前按 ResourceId 执行实时 Check。

HuiceLoginAgent 负责：

- 复用指定资源已有的 ERP 会话或产品选择页。
- 仅在真实未登录时消费一次性受控凭据。
- 在同一 ResourceId、端口、Chrome 和 Profile 页面上下文中执行慧策同源 HTTP 登录。
- 进入旺店通 ERP 后执行鉴权续接和只读 API 探针。
- 将脱敏登录结果投影回 PortManager 当前状态与登录事件。

插件、调度器、MCP 和 UI 只传 ResourceId 与任务上下文，不读取、传递或持久化明文账号、密码、Cookie、Token 或完整授权头。

## 二、资源与凭据契约

资源事实至少包括：

- `resourceId`、`platformId`、host、port、connectionMode。
- browserExecutable、browserProfileDirectory、profileFingerprint。
- platformUrlPatterns、loginPagePatterns。
- credentialRef、maskedAccountSummary、loginAutomationState、sessionPolicy。

`credentialRef` 是受控凭据提供器的不透明引用，不是密码。独立人工恢复和最终用户验收使用 PowerShell `Read-Host`：企业/卖家账号和操作员账号仅在当前进程内存中存在，密码以 SecureString 读取且不回显。正式集成由 PortManager 的 CredentialRef/受控凭据提供器交付一次性内存对象；LoginAgent 消费后立即释放引用。

凭据禁止进入命令行参数、环境变量、SQLite、JSON、日志、文档、临时文件、审计正文或 Git。

## 三、登录执行顺序

1. 解析 ResourceId 并校验资源启用、端口、Profile 和租约。
2. 实时检查 CDP 页面与 API 状态。
3. 若已是 `logged-in-api-ready`，立即复用，不询问凭据、不新开 Profile。
4. 若停在产品选择页，自动进入“旺店通ERP3.0”，然后执行 API 探针。
5. 仅在明确登录页状态下读取受控凭据和服务协议确认。
6. 在该资源现有页面上下文中调用 `HuiceLoginAgent` 的同源 HTTP 登录链路；发布实现不包含 Chrome 表单填写或点击的竞争登录实现。
7. 登录成功后进入 ERP，执行 auth refresh 和 goods overview 只读探针。
8. 只有登录、ERP 页面、refresh 和必要探针字段全部成功，才返回 `logged-in-api-ready`。
9. 保存脱敏状态、时间、证据摘要和错误分类；finally 释放租约。

验证码、短信、滑块、二维码或二次确认属于外部安全边界。程序必须返回明确错误码和下一步，不能把等待人工、页面打开或 HTTP 200 单独当作登录成功。

## 四、登录状态机

当前登录状态：

- `未检测`：尚无实时结果。
- `未登录`：当前页面明确匹配登录页规则。
- `已登录`：同源鉴权续接与规定的只读 API 探针均成功。
- `登录状态未知`：页面可访问但证据不足，或探针未形成明确结论。
- `检测失败`：CDP、HTTP、SQLite 或检测器异常。
- `登录已失效`：历史曾登录，本次明确返回登录页、会话无效或鉴权失败。

判定原则：

1. 端口、Chrome 或 CDP 不可连接时，不能沿用旧成功状态。
2. 明确登录页优先判定未登录或登录已失效。
3. “页面不是登录页”“端口可连”“Chrome 可连”都不是已登录证据。
4. 只有启用的鉴权证据规则真实通过，才能标记已登录。
5. 没有充分证据时使用适配器 `unknownPolicy`：保持登录状态未知。
6. 当前状态由 `port_runtime_states` 输出；历史事件和兼容投影不得反向覆盖当前状态。

## 五、登录页与已登录证据

登录页检测使用适配器 `loginPagePatterns`，包括 `login.huice.com` 和受控慧策/旺店通登录地址模式。命中登录页只能证明“未登录”，不能证明凭据错误或接口不可用。

当前启用的鉴权规则为 `huice-live-cdp-storage-and-api-v1`，约束包括：

- 只在慧策受控域名和目标业务页执行。
- 从当前 CDP 页面上下文使用实时会话材料，不扫描 Profile LevelDB。
- 要求真实鉴权刷新成功。
- 要求 goods overview 只读探针成功并包含必要字段。
- Token/Cookie 只在浏览器会话上下文或受控内存中使用，不写入数据库或日志。

适配器当前契约：

```json
{
  "authenticatedEvidenceRules": [
    {
      "id": "huice-live-cdp-storage-and-api-v1",
      "enabled": true,
      "requiresTargetBusinessPage": true,
      "requiresReadOnlyApiProbe": true
    }
  ],
  "authenticatedEvidenceAvailable": true,
  "unknownPolicy": "没有真实鉴权证据时保持登录状态未知"
}
```

## 六、状态持久化

登录和 Check 结果写入：

- `port_runtime_states`：唯一当前状态真源，包含 loginStatus、loginApiProbeStatus、loginConfidence、lastAuthenticatedAt、检查时间、浏览器/Watcher 状态和脱敏错误。
- `login_session_events`：追加式正式历史事件。
- `login_sessions`：旧兼容投影，只允许由当前状态单向更新。
- `audit_records`：操作、结果、错误码和脱敏摘要。
- `credential_profiles`：只存 CredentialRef、类型和脱敏账号摘要。

严禁保存密码、验证码、Token、Cookie、完整授权头或原始登录响应。任何状态保存失败都必须让 Login 返回失败，不能出现“终端成功但数据库未记录”。

## 七、租约与复用

Login、Check、Open、Watch 和维护动作使用同一资源租约契约：

- 只有持有有效租约的操作才能改变该资源状态。
- 存活且进程身份一致的租约不能被误释放。
- owner PID 不存在、进程启动时间不匹配或租约过期时，下一次 Occupancy/Check/Login/Open 可安全回收并审计。
- 正常完成、异常、超时或后续自愈后活动租约必须归零。

相同账号资源的正式复用决策只使用 CredentialRef、脱敏安全匹配键、实时 Check 和租约状态，不以明文密码查询。存在健康 ready 资源时直接复用；只有无可复用资源时才进入登录。

## 八、Watcher 边界

Watcher 是可选异步维护进程，不是登录事实源。存活必须同时满足 PID、进程启动时间、命令身份和 ResourceId。失活时清除有效 PID/心跳/nextCheck 表象并保留明确错误；按需 Check 可以恢复状态新鲜度，但不等于伪造或恢复 Watcher。

## 九、失败分类

至少区分：

- 资源不存在、禁用、Profile 不存在。
- 端口不可连接、Chrome/CDP 不可连接、慧策页面不存在。
- 登录页、凭据失败、服务协议未确认。
- 验证码或其他安全验证。
- HTTP 401、403、Invalid Token、权限不足、业务错误和网络错误。
- API 探针字段缺失。
- SQLite 写入失败、租约冲突和租约 owner 失活。

错误输出必须使用单一 JSON 信封或简明中文，并提供一个可执行 nextAction；不得统一吞成超时或通用异常。

## 十、验证与演进

发布前至少验证：

- 设计文档、适配器关键值和 `Invoke-HuiceHttpLogin` 实现一致。
- 未登录分类、已登录复用、API 探针、状态落库和活动租约归零。
- 无凭据 NonInteractive 复用不创建新窗口、端口或 Profile。
- 完整 Read-Host 登录只在用户提供隔离资源与真实凭据时验收。
- 外部安全验证未完成时明确标记未验证或阻断。

如适配器的证据规则数量、autoLoginImplemented、loginAdapter 或登录链路类型变化，必须同时更新本文件和静态一致性检查，不允许文档再次保留为相反的运行结论。
