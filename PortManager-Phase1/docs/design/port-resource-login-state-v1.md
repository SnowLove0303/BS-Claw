# BSClaw 端口资源与登录状态设计 v1

> **历史基线（已废弃，不得作为当前运行契约）**
>
> 本文主体记录第一阶段“只检测、不自动登录”的早期设计。当前正式契约以
> `adapter\bsclaw-port-adapter.json`、`HuiceLoginAgent\docs\http-login-contract.md`
> 和实际回归测试为准：适配器已有启用的鉴权证据规则，
> `autoLoginImplemented=true`；Login 先实时复用健康会话，未登录时只在同一
> ResourceId/端口/Profile 的 `login.huice.com` 上下文执行同源 HTTP 登录，
> 进入 ERP 后以 auth refresh 与只读 API 探针确认并持久化状态。PowerShell
> 凭据只在受控内存中使用，浏览器 DOM 表单填写不是实现路径。

## 一、设计目标

本设计用于独立 PowerShell 端口管理模块，目标是让普通用户从菜单 1 完成慧策通资源注册，并在注册、检测和打开后得到可持久化、可复核的分层状态。

本阶段只检测登录状态，不自动填写账号密码，不保存密码，不读取或复制 Cookie、Token、完整授权头或浏览器存储。没有真实鉴权证据时必须返回“登录状态未知”。

## 二、边界

允许：

- 读取真实本机端口监听状态。
- 读取 Chrome `/json/version`、`/json/list`。
- 读取页面 URL、标题和加载状态。
- 按适配器登记的明确登录页规则判断“未登录”。
- 通过受控、只读、已登记的鉴权证据提供器判断“已登录”。
- 保存脱敏证据摘要、检测时间和失败原因。

禁止：

- 读取、复制或保存 Cookie、Token、密码、完整授权头和浏览器存储。
- 使用“端口可连接”“Chrome 可连接”“页面不是登录页”推断已登录。
- 执行账号密码自动登录。
- 在适配器 JSON 中放置任意 JavaScript、任意 URL 或任意 HTTP 请求。
- 修改或接入 `F:\XIANGMU\BS Claw\System`。

## 三、模块边界

实现拆分为以下职责：

1. `PortManager.Registration.psm1`：注册向导、默认值、普通流程和高级流程参数计划。
2. `PortManager.Login.psm1`：登录证据判定、证据脱敏、登录状态转换。
3. `PortManager.State.psm1`：资源 Schema、状态默认值、旧数据升级和状态机。
4. `PortManager.Persistence.psm1`：F 盘路径约束、互斥写锁、原子 JSON、备份和敏感字段阻断；Core 提供资源/审计编排。
5. `PortManager.Chrome.psm1`：Chrome 启动和本次进程回收；慧策适配器模块提供 Chrome/CDP 发现与平台默认规则。
6. `PortManager.Output.psm1`：中文文本、纯 JSON 信封和单一下一步动作。
7. `PortManager.Core.psm1`：端口资源服务、租约、占用与操作编排。
8. `port-manager.ps1`：参数入口、菜单路由和模块调用，不保存业务规则。

## 四、登录状态机

允许状态：

- `未检测`：资源尚未执行登录检测。
- `未登录`：当前页面匹配明确登录页规则。
- `已登录`：至少一条受控鉴权证据规则真实通过。
- `登录状态未知`：页面可访问，但没有充分鉴权证据；或页面不完整、规则不匹配、网络超时。
- `检测失败`：登录检测器自身异常，不能等同于未登录。
- `登录已失效`：历史状态为已登录，本次明确出现登录页或受控鉴权规则明确返回会话无效。

判定顺序：

1. 端口和 Chrome 调试接口不可访问：本次登录状态为`登录状态未知`；检测器异常时为`检测失败`。
2. 没有慧策页面：`登录状态未知`。
3. 页面匹配明确登录页：历史不是已登录时为`未登录`；历史为已登录时为`登录已失效`。
4. 受控鉴权证据通过：`已登录`。
5. 受控鉴权证据明确返回会话无效，且历史为已登录：`登录已失效`。
6. 其余情况：`登录状态未知`。

任何新检测都会覆盖旧的当前登录状态，旧状态只作为状态转换输入，不能继续显示为已登录。

## 五、登录证据模型

JSON 字段 `lastStatus.loginEvidence`：

```json
{
  "state": "登录状态未知",
  "evidenceType": "none",
  "evidenceSummary": "页面属于慧策，但适配器没有可用的真实鉴权证据规则。",
  "pageUrl": "https://erp.huice.com/",
  "pageTitle": "旺店通 | 慧策",
  "checkedAt": "2026-07-28T00:00:00+08:00",
  "confidence": "unknown",
  "source": "bsclaw.huice.login-detector",
  "evidenceVersion": "1"
}
```

安全要求：

- `pageUrl` 只保存 `scheme + host + path`，删除 query、fragment 和用户信息。
- `pageTitle` 去除控制字符并限制长度。
- `evidenceSummary` 只能写规则 ID、布尔结果和中文摘要，不写响应正文。
- `evidenceType` 只允许 `none`、`login-page-rule`、`authenticated-rule`、`detector-error`、`session-invalidated`。
- `source` 是固定提供器 ID，不能保存任意调用地址。

## 六、适配器登录检测契约

`adapter.huiceAdapter.loginDetection`：

```json
{
  "states": [
    "未检测",
    "未登录",
    "已登录",
    "登录状态未知",
    "检测失败",
    "登录已失效"
  ],
  "loginPagePatterns": [],
  "authenticatedEvidenceRules": [],
  "unknownPolicy": "没有真实鉴权证据时保持登录状态未知",
  "evidenceVersion": "1"
}
```

`authenticatedEvidenceRules` 只登记受控提供器：

```json
{
  "ruleId": "huice-authenticated-session-v1",
  "providerId": "huice-readonly-session-probe",
  "allowedHosts": ["erp.huice.com"],
  "enabled": false
}
```

适配器不保存任意表达式或任意接口。没有经过真实环境确认的提供器时数组必须为空，系统不能产生“已登录”。

## 七、资源 JSON Schema v2

资源新增：

```json
{
  "platformId": "huice",
  "credentialRef": null,
  "maskedAccountSummary": null,
  "loginAutomationState": "未配置凭据",
  "sessionPolicy": {
    "autoLoginEnabled": false,
    "credentialRefRequired": true,
    "requireHumanConfirmation": true,
    "profilePersistence": "resource-owned-f-drive-profile",
    "maxSessionAgeSeconds": 0,
    "recheckBeforeUse": true
  }
}
```

状态新增：

```json
{
  "loginStatus": "未检测",
  "loginEvidence": {},
  "loginCheckedAt": null,
  "currentOccupancyDetails": {
    "activeLeases": [],
    "ownerProcessIds": [],
    "operation": null,
    "checkedAt": null
  }
}
```

约束：

- `credentialRef` 只允许受控凭据存储返回的不透明引用；本阶段固定为 `null`。
- `autoLoginEnabled` 本阶段固定为 `false`。
- profile 必须位于 F 盘，并记录资源归属；删除资源不自动删除 profile。
- 旧 Schema v1 在读取时升级为 v2 默认字段，原文件通过现有原子写入和备份机制保存。

## 八、未来 SQL 映射

本阶段不创建数据库。未来 `port_resources` 表映射：

| SQL 字段 | JSON 来源 | 说明 |
|---|---|---|
| `resource_id` | `resourceId` | HCP 主键 |
| `platform_id` | `platformId` | 当前为 huice |
| `resource_name` | `resourceName` | 用户可读名称 |
| `host_name` / `port` | 同名字段 | 调试地址 |
| `connection_mode` | `connectionMode` | 内部枚举 |
| `browser_executable` | `browserExecutable` | Google Chrome |
| `browser_profile_directory` | `browserProfileDirectory` | F 盘 profile |
| `start_url` / `enabled` | 同名字段 | 平台入口与启用状态 |
| `connection_status` | `lastStatus.connectionStatus` | 连接层 |
| `browser_status` | `lastStatus.browserStatus` | Chrome/CDP 层 |
| `page_status` | `lastStatus.pageStatus` | 慧策页面层 |
| `login_status` | `lastStatus.loginStatus` | 登录状态机 |
| `login_evidence_json` | `lastStatus.loginEvidence` | 脱敏证据 |
| `login_checked_at` | `lastStatus.loginCheckedAt` | 登录检测时间 |
| `last_checked_at` / `last_error` | `lastStatus` | 最近检测 |
| `current_occupancy_json` | `lastStatus.currentOccupancyDetails` | 租约和进程 |
| `credential_ref` | `credentialRef` | 不透明引用 |
| `session_policy_json` | `sessionPolicy` | 会话策略 |
| `created_at` / `updated_at` | `registeredAt` / `updatedAt` | 时间 |

未来 `login_attempts` 只保存 attempt ID、resource ID、credential ref、状态、失败类型、开始/结束时间和 audit ID，不保存提交内容或凭据原文。

## 九、注册流程

```text
菜单 1
  -> 自动发现真实 Chrome 慧策页面
  -> 已发现：默认使用现有 Chrome
  -> 未发现：默认自动启动 Google Chrome
       -> 自动寻找 chrome.exe
       -> 自动分配空闲端口
       -> 自动创建 F 盘 profile
  -> 资源名称可直接回车
  -> 创建 Schema v2 资源
  -> 立即检测 TCP / Chrome / 页面 / 登录
  -> 保存状态和脱敏证据
  -> 立即打开 / 再次检测 / 返回菜单
```

普通流程不显示 CDP、ConnectOnly、Launch、Pattern、端口和 Chrome 路径。技术字段只存在于高级设置与机器接口。

## 十、未来自动登录接口边界

预留状态：

- `未配置凭据`
- `等待凭据`
- `登录中`
- `登录成功`
- `登录失败`
- `验证码/人工处理`
- `会话过期`
- `未知`

未来登录请求必须只接收 `resourceId`、`credentialRef`、人工确认、超时和幂等键。执行前重新检测登录状态；完成后重新执行只读登录检测。凭据解析只允许在独立受控凭据提供器中发生。

## 十一、Pynes 参考与差异

只读检查结果：

- `F:\XIANGMU\AI dianshang\系统` 不存在，未读取到原 Pynes 源码。
- 现存 `F:\XIANGMU\AI dianshang` 含历史资料和可能敏感的业务输出，本设计未读取这些输出。
- AIstudy Pynes 文档可确认的抽象经验是统一入口、分层状态、资源锁、结果记录和重启恢复。

借鉴的抽象经验：

- 连接、浏览器、页面和登录分层。
- 任务/资源锁与状态持久化。
- 未知状态不能静态推断成功。
- 重启后重新核对现场状态。

BS Claw 新实现：

- HCP 端口资源 Schema v2。
- 六态 loginStatus 状态机。
- loginEvidence 和 sessionPolicy 安全模型。
- Credential Ref 与未来 login attempts 边界。
- F 盘 Chrome profile 资源归属。
- PowerShell 租约、进程占用和 JSON/插件适配契约。

本设计不复制 Pynes 字段、数据库、主进程、凭据、UI 或业务流程，也不声明与未读取源码兼容。

## 十二、验证门

自动化必须验证：

- Schema v1 到 v2 升级和重启回读。
- 明确登录页为未登录。
- 页面正确但无鉴权规则为登录状态未知。
- 检测异常为检测失败。
- 历史已登录后出现登录页为登录已失效。
- 重复检测更新证据和时间。
- 失败后旧“已登录”不能残留。
- JSON、日志和运行目录敏感信息扫描。

真实慧策已登录只有在受控鉴权规则经过真实环境确认后才能判定。没有该证据时，对应验收项保持“未验证”。
