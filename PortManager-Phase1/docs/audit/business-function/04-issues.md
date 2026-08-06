# 问题记录

## BF-P0-001 注册正常路径在空监听进程集合上崩溃

- 功能/流程：Register，正常注册未监听的真实本机端口。
- 触发条件：`HostName=127.0.0.1`，端口未监听，`ConnectionMode=ConnectOnly`，使用 `-NonInteractive -OutputFormat Json`。
- 步骤：在隔离副本空 `data/ports.json` 上执行注册命令。
- 预期：端口未监听时应创建资源，状态表达“不可连接/未监听”，并返回可解析的成功 JSON。
- 实际：退出码 1，JSON `success=false`，错误为“在此对象上找不到属性‘Count’”。
- 影响：第一阶段核心验收“注册创建一个慧策通端口”无法完成；详情、检测、打开、启停、删除等后续流程没有资源编号可用。该错误还遮蔽了无效主机等输入的业务语义。
- 证据：`F:\XIANGMU\BS Claw\_audit-runtime\business-flow-20260727-02`；复现命令见 `03-test-results.md`。
- 根因：`ConvertTo-PMPatternArray` 在无规则时不产生管道对象，调用方直接访问空结果的 `.Count`；同类条件数组赋值也可能把空数组退化为 `$null`。
- 修复：所有需要计数的集合显式使用外层数组包装，并保持规则字段为空数组。
- 影响范围：Register、状态初始化、后续规则匹配。
- 当前状态：已修复并通过空库、未监听端口、重复注册及监听冲突回归。

## BF-P1-002 JSON 输出契约需继续验证（已由静态审计发现，待资源链路恢复后复测）

编辑、删除流程内部原先先输出文本提示，再输出 JSON。

- 根因：Text 与 Json 共用交互函数，函数内无输出模式隔离。
- 修复：Json/NonInteractive 模式只从已绑定参数构造编辑变更；删除必须显式提供确认文本；提示、表格和 Read-Host 只允许 Text 模式。
- 影响范围：Edit、Delete 及缺参数失败契约。
- 当前状态：已修复；成功与失败 stdout 均可直接解析为单一 JSON，失败退出码为 1。

## BF-P1-003 检测/打开失败状态与状态持久化需在真实资源上复测

### BF-P1-003 Check/Open 失败状态未可靠持久化

- 根因：Check 异常分支只写审计/日志；Open 多个异常在保存最终状态前抛出。
- 修复：增加统一失败状态构造；Check 异常先保存“检测失败”；Open 清理后重新检测真实层级，并保存 `operationStatus=打开失败` 和本次错误。
- 影响范围：`ports.json`、List、Detail、CheckAll、Open。
- 当前状态：已修复；不可连接 Check 和 Open 失败后的跨进程 Detail/状态文件回读通过。

### BF-P1-004 Open 失败遗留本次浏览器进程

- 根因：原 catch/finally 只释放租约，没有记录或停止本次 Start-Process 创建的浏览器进程树。
- 修复：按根 PID、子进程、调试端口、F 盘 profile 和创建时间识别本次拥有的进程；失败时先回收，再保存状态，最后释放租约。既有浏览器不会被回收。
- 影响范围：Launch 模式所有 CDP、页面、超时和回查失败。
- 当前状态：最新回归已使用真实 Google Chrome/CDP 验证；失败后匹配进程 0、租约 0、状态为“打开失败”。历史 Edge 证据不作为当前 Chrome-only 结论。

### BF-P1-005 ConnectOnly 远程控制边界过宽

- 根因：注册接受任意合法 DNS/公网地址，Open-PMTargetPage 没有独立回环防线。
- 修复：登记只接受 localhost 或明确的回环、RFC1918、链路本地、IPv6 ULA IP；拒绝远程 DNS 和公网 IP；远程私网只允许状态读取；Open 及 `/json/new`、`/json/activate` 仅允许回环。
- 影响范围：Register、Edit、Check、Open。
- 当前状态：公网拒绝、私网登记、私网 Open 拒绝回归通过。

### BF-P2-006 Edit/Delete 存在检查—写入竞态

- 根因：占用检查在获取写锁前完成，检查后到保存前可能插入新租约。
- 修复：Update/Remove 在写锁内重新读取资源，并在同一锁内再次检查最新租约和监听进程后才修改。
- 影响范围：Edit、Enable、Disable、Delete 与并发 Open。
- 当前状态：活动租约期间 Edit/Delete/Open 均被拒绝，租约结束后无残留。

### BF-P2-007 租约占用与 List/Detail 展示不一致

- 根因：`lastStatus.currentOccupancy` 只记录监听进程，租约写入与释放未同步状态；List/Detail 直接显示旧值。
- 修复：占用模型合并 `activeLeases` 与 `ownerProcessIds`；建立/释放租约时更新存储，List/Detail 每次读取再叠加实时占用视图。
- 影响范围：List、Detail、Check、Open、适配器 JSON。
- 当前状态：租约期间 List/Detail 均显示租约操作与 PID，释放后显示无占用。

## 2026-07-28 首次操作路径打回项

### BF-P0-016 / BF-P1-017 至 BF-P1-023 注册入口不具备最简业务路径

- 根因：普通注册直接复用了完整技术参数模型，把资源名、端口、连接枚举、浏览器路径、profile、URL 和匹配规则全部暴露给首次用户。
- 修复：新增慧策适配模块与业务向导；先自动发现已打开的慧策 Chrome，未发现则默认自动启动 Chrome。端口、Chrome 路径、F 盘 profile、页面规则、启用状态和备注均使用安全默认，名称最后输入且可直接回车。
- 流程衔接：注册后自动 Check，再提供“立即打开 / 再次检查 / 返回菜单”，无需复制资源编号或 PowerShell 命令。
- 影响范围：Register 菜单、Chrome 检测、慧策默认规则、注册后流程、Skill 与适配契约。
- 当前状态：RG-015、RG-016 自动回归通过；真实慧策环境人工复测待用户执行，审计未判定通过。

### BF-P1-024 运行数据与启动当前目录耦合

- 根因：默认数据根曾由源码目录和启动位置隐式决定，可能污染 `data\ports.json`。
- 修复：默认运行根固定解析为项目 `runtime`；测试仍可用进程环境变量定向到 F 盘隔离目录；主文件不可读时保留原件并从有效备份恢复。
- 影响范围：资源、状态、租约、审计、日志、浏览器 profile 与异常恢复。
- 当前状态：任意当前目录、源码 data 哈希及备份恢复回归通过。

### BF-P2-025 失败反馈技术化且缺少动作

- 根因：状态输出只报告底层层级和错误，用户不知道下一步；不同分支可能堆叠多条建议。
- 修复：保留端口/HTTP/CDP/页面/登录证据，同时统一映射为一项中文 `nextAction`；文本输出只显示一个“下一步”。
- 影响范围：Check、Open、菜单异常和 JSON 信封。
- 当前状态：RG-019 自动回归通过；真实慧策失败文案仍需用户现场评价。
