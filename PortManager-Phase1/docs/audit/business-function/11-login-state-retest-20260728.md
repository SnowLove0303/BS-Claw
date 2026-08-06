# 登录状态与注册模型开发复验（2026-07-28）

## 1. 本次任务范围

本次只复验独立项目中的注册向导、端口资源 schema v2、Google Chrome 生命周期、慧策页面分层状态和登录证据边界。未修改或接入 `F:\XIANGMU\BS Claw\System`，未实现账号密码自动填写、Credential 存储、Cookie/Token 读取、商品、订单或其他慧策业务动作。

## 2. 实现结论

- 普通菜单 1 保持业务向导：只选择“使用已打开的慧策通”或“自动启动新的 Chrome”，普通流程不要求输入 CDP、连接枚举、端口、Chrome 路径或页面规则。
- 新资源使用 schema v2，保存 `platformId`、`credentialRef`、`maskedAccountSummary`、`loginAutomationState`、`sessionPolicy`、`lastStatus.loginEvidence` 和 `lastStatus.loginCheckedAt`。
- `credentialRef` 当前为空，`sessionPolicy.autoLoginEnabled=false`；没有保存密码、Cookie、Token 或完整授权头。
- 登录状态与端口、Chrome、页面状态分开。明确登录页判为“未登录”；没有已启用的真实鉴权规则时保持“登录状态未知”；检测异常使用“检测失败”；“已登录”和“登录已失效”只有在未来接入真实鉴权证据后才可形成完整闭环。
- 当前适配器 `authenticatedEvidenceRules` 为空，因此程序没有任何代码路径把普通页面、标题、端口或历史记录推断为“已登录”。

## 3. 实际执行证据

### 3.1 静态与原业务回归

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-static-validation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-business-regression.ps1
```

- 静态回归使用唯一 F 盘目录，6 项通过；空库 List 确认为空数组。
- 原业务回归在同步适配器版本断言前为 19/20，唯一失败是测试仍预期旧版本 `0.2.0`，实现版本为 `0.3.0`。该测试契约已同步，最终结果以最新运行摘要为准。
- 静态回归前后，用户真实 `runtime\data\ports.json` 的 SHA-256 和最后写入时间不变。

### 3.2 真实慧策登录页与真实现有页面

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-login-state-regression.ps1
```

隔离运行目录：

```text
F:\XIANGMU\BS Claw\PortManager-Phase1\tests\runtime\login-state-regression-20260728-145217-719283d3b9304f1aa02f14b5b73d2f80
```

最终专项回归 10 项通过、0 项失败：

| 场景 | 实际结果 | 证据 |
|---|---|---|
| Chrome 发现 | 只使用真实 Google Chrome，不回退 Edge | `chrome.exe` 实际路径 |
| schema v2 注册 | 成功 | `platformId=huice`、`credentialRef=null`、自动登录关闭 |
| 真实登录页 Open | 成功 | 浏览器可连接、平台页面正确、`loginStatus=未登录` |
| 登录页证据 | 成功 | `evidenceType=login-page-rule`、确认级证据和检测时间 |
| 重复 Check/Detail | 成功 | 状态、证据类型和检测时间持久化一致 |
| 已打开的真实慧策页面 | 成功执行只读判断 | 真实端口 55409、页面 1 个、无鉴权规则时为“登录状态未知” |
| 敏感信息扫描 | 未发现禁止字段 | 扫描程序管理的 data/log 文件；未读取 Chrome 原生 profile |
| 测试收口 | 成功 | 本轮 Chrome 残留进程 0、租约 0 |
| Chrome 关闭后复查 | 成功 | 浏览器未连接，旧“未登录”更新为“登录状态未知”并持久化 |
| 收口后敏感复扫 | 未发现禁止字段 | 最终 data/log 共 5 个程序管理文件 |

测试只读取 CDP `/json/version` 和 `/json/list` 的页面 URL、标题和状态，不读取 Cookie、Token、密码、授权头或浏览器存储。真实现有慧策页面没有充分鉴权证据，因此明确返回“登录状态未知”，没有宣称已登录。

## 4. Pynes 参考与差异

可参考的只有抽象经验：端口连通、浏览器调试接口、平台页面、登录页、鉴权证据、未知状态、检测时间和失败原因应分层。

BS Claw 本次新实现包括：六态 `loginStatus`、`loginEvidence`、`sessionPolicy`、Credential Ref 边界、资源归属的 F 盘 Chrome profile、操作租约和任务占用关系。没有复制 Pynes 的字段、数据库、主进程调用、凭据处理或 UI。

指定的原 Pynes 源码目录 `F:\XIANGMU\AI dianshang\系统` 在现场不存在；本次没有读取原源码，也不声称源码兼容。只读查看了 AIstudy 中 Pynes 的阶段需求/优化方向，用于核对抽象分层经验。

## 5. 未验证与后续范围

- 没有经确认的慧策只读鉴权接口或规则，因此“已登录”真实证据未验证。
- 因“已登录”前置状态尚未真实形成，“登录已失效”的真实会话复查未验证。
- 账号密码输入、自动登录、Credential Ref 后端、验证码/人工处理、会话复用和 `login_attempts` 仅为后续契约，不属于本次实现。
- BS Claw 主系统加载、SQL 表落库和插件任务调度未开发。
- 最终业务验收仍由用户从菜单 1 按真实账号环境复测，本文件不判定最终通过。
