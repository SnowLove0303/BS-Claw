# 首次注册向导优化自动回归摘要（历史记录，已被 2026-07-29 打回复测覆盖）

> 本文件记录的是 2026-07-28 旧回归，不能作为当前审计通过证据；其中任何旧的浏览器/脚本路径只保留历史事实。当前可采信证据见 `docs/audit/business-function/16-rejection-closure-20260729.md`，真实慧策登录鉴权仍未验证。

最终执行时间：2026-07-28 14:41—14:44（Asia/Shanghai）

执行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-business-regression.ps1
```

隔离运行目录：

```text
F:\XIANGMU\BS Claw\PortManager-Phase1\tests\runtime\business-regression-20260728-145446-741f8671175b42c996b5d1738c9df5e4
```

结果：20 项通过，0 项失败。

本次新增关键证据：

- 首次注册业务向导：菜单 1 后选择自动启动 Chrome，资源名称直接回车，退出码 0。
- 自动生成资源：`HCP-DAD23E4B` / `慧策通端口-59982`；端口由真实本机空闲端口分配。
- Chrome 自动检测：`E:\MorenAnzhuangLujing\Chrome\Chrome\Application\chrome.exe`；没有回退 Edge。
- 配置目录：隔离 F 盘 `browser-profiles\huice-59982`；普通流程没有出现 ConnectOnly、Launch、URL Pattern、Login Pattern 等技术提示。
- 慧策适配默认值：`https://login.huice.com/`、平台规则和登录页规则均由适配器提供。
- 注册后自动启动：真实结果为“浏览器可连接 / 平台页面正确 / 未登录”，证据类型为 `login-page-rule`；测试后匹配进程 0、租约 0。
- 任意当前目录启动：数据仍写入项目 `data\port-manager.sqlite3`，`ports.json` 仅保留作迁移/回滚输入。
- 异常恢复：SQLite 写入失败时停止写入并保留迁移备份；不得用空 JSON 覆盖数据库。

既有回归证据：

- 未监听端口注册、无效端口/主机、重复注册、真实监听冲突。
- Edit/Delete 成功和失败 stdout 均为单一 JSON；失败退出码非零。
- Check/Open 失败后的最新状态可由 Detail 与状态文件回读。
- ConnectOnly 公网/远程 DNS 拒绝，私网只读登记，远程 Open 拒绝。
- 并发租约期间 List/Detail 展示占用，Edit/Delete/Open 均拒绝。
- 使用真实 Google Chrome 执行失败回收路径；Open 失败后残留匹配进程 0、租约 0。
- BS Claw 主系统工作树干净，HEAD 保持 `b1c668078d8959793ba2f4698efc751b9e315567`。

未执行且不得宣称通过：

- 真实慧策账号登录、退出登录或独立鉴权证据。
- 历史已登录会话失效后的真实转换。
- 自动登录、Credential Ref 后端和会话复用。
- BS Claw 主系统实际加载适配器。

完整机器证据位于隔离运行目录的 `business-regression-summary.json`。本历史结果不表示当前业务审计通过；需按最新收口记录和 `real-validation-record.md` 由用户复测。
