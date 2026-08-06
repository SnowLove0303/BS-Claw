# 自动化实际测试结果

| 用例 | 实际结果 | 证据 |
|---|---|---|
| 空库 List JSON | 通过：退出码 0，返回 `success=true`、空数组 | 隔离副本命令输出 |
| 正常注册：127.0.0.1 + 未监听端口 + ConnectOnly | 失败：退出码 1，返回“找不到属性 Count” | 隔离副本命令输出 |
| 无效端口 0 | 通过拒绝：退出码 1，返回端口范围错误 | 隔离副本命令输出 |
| 无效主机 | 失败：同样返回“找不到属性 Count”，未到达主机语义错误 | 隔离副本命令输出 |
| 不存在资源 Detail | 通过拒绝：退出码 1，JSON `success=false` | 隔离副本命令输出 |
| 空库 CheckAll JSON | 通过：退出码 0，返回空结果 | 隔离副本命令输出 |
| 中文菜单退出 | 通过：输入 0 后正常退出 | 隔离副本命令输出 |
| 中文菜单查看列表 | 通过：输入 2 后显示空库并在 EOF 安全退出 | 隔离副本命令输出 |

本次未伪造浏览器、CDP、慧策页面、登录状态或测试资源；真实环境闭环保持未测。

## 优化后自动化复验

执行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-business-regression.ps1
```

执行环境：Windows PowerShell `5.1.26100.8875`。

| 用例 | 退出码/解析 | 状态文件、进程或租约证据 | 结果 |
|---|---|---|---|
| 空库 List | 0，JSON 可解析 | 空数组 | 通过 |
| 未监听端口注册 | 0，JSON 可解析 | `不可连接`、`登录状态未知` | 通过 |
| 无效端口 | 1，失败 JSON | 未写入资源 | 通过拒绝 |
| 无效主机 | 1，失败 JSON | 返回主机格式错误 | 通过拒绝 |
| 重复注册 | 1，失败 JSON | 返回已有资源编号 | 通过拒绝 |
| 真实监听冲突 | 1，失败 JSON | 识别实际 PowerShell 监听 PID | 通过拒绝 |
| Detail/List 持久化 | 0/0，JSON 可解析 | 跨进程读取同一资源编号 | 通过 |
| Edit JSON | 0，stdout 单一 JSON，stderr 空 | 修改内容持久化 | 通过 |
| Delete JSON | 缺确认 1；正确确认 0 | 两次 stdout 均为单一 JSON | 通过 |
| Check 不可连接 | 0，状态 JSON | `ports.json` 的检测时间与输出一致 | 通过 |
| Open ConnectOnly 失败 | 1，失败 JSON | `operationStatus=打开失败`，租约 0 | 通过 |
| 远程边界 | 公网注册 1；私网注册 0；私网 Open 1 | 未对远程地址执行控制写操作 | 通过 |
| 并发租约保护 | Edit/Delete/Open 均为 1 | List/Detail 显示租约，结束后租约 0 | 通过 |
| 真实 Google Chrome 失败回收 | Open 1，失败 JSON | 残留进程 0，租约 0，最新状态“打开失败” | 通过 |
| 生产隔离 | 0 | 生产数据哈希未变，主系统工作树干净 | 通过 |

该历史轮汇总：15 项通过，0 项失败；当时使用 Edge 验证失败清理。当前 BF-P1-020 已禁止 Edge 回退，最新 Google Chrome 证据见下节。

## 2026-07-28 首次注册优化复验

执行时间：2026-07-28 09:56—09:58。隔离运行目录：

```text
F:\XIANGMU\BS Claw\PortManager-Phase1\tests\runtime\business-regression-20260728-095632-d4960e869a634cc3b6d517e11b9e4b25
```

| 用例 | 实际证据 | 结果 |
|---|---|---|
| 首次注册向导 | 菜单 1，选择自动 Chrome，名称回车；创建 `HCP-F28910DE` / `慧策通端口-55978` | 通过 |
| 技术字段隐藏 | 普通输出不含 ConnectOnly、Launch、URL Pattern、Login Pattern 或复制命令 | 通过 |
| 自动端口/Chrome/profile | 真实空闲端口 55978；真实 `chrome.exe`；F 盘隔离 profile | 通过 |
| 慧策适配默认值 | 默认页 `https://login.huice.com/`，平台/登录规则非空 | 通过 |
| 注册后自动检查 | 返回不可连接、浏览器未连接、页面未知、登录未知；未伪造成功 | 通过 |
| 单一下一步动作 | 注册检查输出 1 个“下一步”；JSON 失败含 `nextAction` | 通过 |
| 任意当前目录 | 数据写入项目 `runtime`，源码 data 哈希未变 | 通过 |
| 异常恢复 | 损坏主文件保留不可读副本并从备份恢复 | 通过 |
| 完整回归 | RG-001 至 RG-020 | 20 通过，0 失败 |

本表只证明开发自动化结果。真实慧策页面、真实账号登录和成功 Open 未执行，本次审计仍等待用户人工复测。

## 2026-07-28 登录状态模型开发复验

执行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-login-state-regression.ps1
```

真实 Google Chrome 使用独立 F 盘 profile 打开 `https://login.huice.com/`，Open 退出码 0；实际状态为“浏览器可连接 / 平台页面正确 / 未登录”，证据类型为 `login-page-rule`。随后 Check 和 Detail 回读一致。另对用户已打开的真实慧策页面执行只读 CDP 判断，在鉴权规则为空时返回“登录状态未知”，没有判定“已登录”。

最终专项回归 10 项通过、0 项失败；测试拥有的 Chrome 进程已精确回收，残留进程 0、租约 0。Chrome 关闭后再次 Check/Detail，旧“未登录”被当前“登录状态未知”覆盖。程序管理的 data/log 文件在收口前后两次敏感信息扫描均无发现。真实“已登录”鉴权证据、登录失效和自动登录仍未验证。
