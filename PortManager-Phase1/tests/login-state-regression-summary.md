# 登录状态专项回归摘要

最终执行时间：2026-07-28 14:44—14:45（Asia/Shanghai）

执行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-login-state-regression.ps1
```

隔离运行目录：

```text
F:\XIANGMU\BS Claw\PortManager-Phase1\tests\runtime\login-state-regression-20260728-145217-719283d3b9304f1aa02f14b5b73d2f80
```

结果：LS-001 至 LS-010 共 10 项通过，0 项失败。

- 真实 Google Chrome，未回退 Edge。
- schema v2 注册成功；`credentialRef=null`，自动登录关闭，人工确认和使用前复查策略存在。
- 真实打开 `https://login.huice.com/`，状态为“浏览器可连接 / 平台页面正确 / 未登录”，证据类型 `login-page-rule`。
- 重复 Check 和 Detail 的状态、证据类型与检测时间持久化一致。
- 适配器真实鉴权规则数为 0，不会产生“已登录”结论。
- 对用户已打开的真实慧策页面执行只读 CDP 判断：真实端口 55409、页面 1 个、结果“登录状态未知”，未读取 Cookie/Token。
- 本轮测试 Chrome 残留进程 0、租约 0。
- Chrome 关闭后再次 Check/Detail，旧“未登录”被当前“登录状态未知”覆盖。
- 程序管理的 data/log 文件在收口前后两次敏感信息扫描均无发现；没有读取或复制 Chrome 原生 profile。

未验证：真实已登录鉴权证据、登录已失效、Credential Ref 后端、自动登录、验证码/人工处理和会话复用。上述项目不得宣称通过。
