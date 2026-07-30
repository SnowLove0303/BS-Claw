# 慧策通端口管理执行规范

## 统一入口与模块边界

唯一推荐入口是 `F:\BS-Claw\PortManager-Phase1\port-manager.ps1`；`scripts\port-manager.ps1` 仅为内部实现。根入口与内部入口的正式 Action 由静态验证检查完全一致，JSON 模式标准输出只允许一个信封。

职责边界：

- PortManager：资源、端口、Profile、租约、当前状态、异步任务和审计真源。
- HuiceLoginAgent：受控登录适配器，只负责真实登录、会话复用、鉴权续接与只读 API 证据。
- `PortManager.Network.psm1`：主机、端口、TCP、HTTP/CDP 网络原语。
- `PortManager.Performance.psm1`：阶段耗时，不参与业务判断。
- `PortManager.StorageAudit.psm1`：全模块只读体积盘点。
- `PortManager.HuiceLoginAdapter.psm1`：PortManager 到登录适配器的稳定 JSON 边界。

插件执行前最小规则：

1. `已登录 + logged-in-api-ready + high` 且 Check 足够新鲜，允许执行。
2. 登录/API ready 但 Watcher 失活时，先按需 Check；成功后属于 degraded-ready，可执行。
3. 未登录、session-expired、API 探针失败或位于登录页时，执行 HuiceLogin。
4. 端口/CDP 不可连接、资源停用、Profile 不存在，或需要自动登录但缺少 CredentialRef 时，不得执行。
5. Watcher 是可选维护进程，不是登录事实源；异步 LoginCheck 必须调用真实慧策适配器，不能用弱证据覆盖 API-ready 状态。

## SQLite 数据与迁移

所有业务操作（注册、列表、详情、编辑、删除、检测、打开、全检）均通过 `PortManager.Sqlite.psm1` 读写 `data\port-manager.sqlite3`。禁止脚本直接编辑 JSON 或直接拼接 SQL。数据库启用 WAL、外键和事务；schema 迁移只新增表、字段和索引，不执行运行时 DROP。

首次运行若发现旧 `ports.json`、`leases.json` 或 `login-detections.json`，会先在 `data\migrations` 生成 `pre-sqlite-baseline.json`、legacy 副本和迁移标记，再在一个事务内导入可安全迁移的资源、状态、租约和检测任务元数据。原 JSON 保留，SQLite 成为唯一运行时真源。租约读取会将明显过期的 active 租约收口为 expired；删除资源会归档检测和审计历史。

数据库损坏、迁移失败或字段校验失败时，程序应停止写入并提示从 `data\migrations` 回滚；不得用空 JSON 覆盖旧数据。运行数据、SQLite WAL/SHM、Python 缓存和测试证据均位于 F 盘。

## 一、执行目标

用户通过资源编号注册、检测并打开一个真实慧策通 Chromium 调试端口，得到端口、浏览器、页面和登录证据的分层中文结果。

## 二、执行前提

1. 使用 Windows PowerShell 5.1 或更高版本。
2. 进入 `F:\BS-Claw\PortManager-Phase1` 后运行根入口；程序从其他当前目录启动时仍把 JSON 数据统一写入项目 `data`。
3. 自动启动方式需要本机安装真实 Google Chrome；程序不会切换到其他浏览器。
4. 程序自动在 F 盘 `F:\BS-Claw\_portmanager-profiles` 创建独立 Chrome 配置；该目录不属于正式 `data`。
5. 测试高风险删除前，确认资源没有活动浏览器进程。

## 端口环境清理与登录重测

三类场景必须分开：

1. `CachePlan` / `CleanCache`：只处理可再生缓存。不会主动退出登录，也不会修改登录成功状态。
2. `CreateLoginTestProfile`：复制资源配置到独立端口和独立空白 Profile，用于重新测试 PowerShell Login；不复制任何秘密或浏览器会话。
3. `DeploymentCleanPlan`：只输出跨机器部署前的保留、可清理和迁移后重建清单。
4. `StorageAudit`：盘点整个模块和全部 Profile，输出体积分类、Top 膨胀项和推广阻断，不删除数据。

`CleanCache` 在 Profile 正在运行时返回 `PM_PROFILE_IN_USE`，不会自动关闭 Chrome。普通 List、Check、Open、Login 不会调用缓存清理。

### 用户人工测试

1. 执行绝对路径 `CachePlan` 命令。通过标准：返回 `success=true`、`executeMode=dry-run`，且 Profile 字节数不下降。
2. Chrome 仍运行时执行 `CleanCache`。通过标准：返回 `PM_PROFILE_IN_USE`，提示先关闭浏览器，Profile 字节数不下降。
3. 执行 `CreateLoginTestProfile`。通过标准：返回新的 ResourceId、独立端口和独立 Profile，状态为“未登录 / login-required / none”，原资源状态不变。
4. 使用返回的新 ResourceId 执行 HuiceLoginAgent Login。只有这一步需要用户在 PowerShell 输入真实账号信息；密码不回显。
5. 迁移前执行 `DeploymentCleanPlan`。通过标准：只输出建议，不删除文件。

失败标准：清理删除非缓存登录数据、普通 Check/Open 隐式触发清理、新测试资源复用原 Profile、失败后遗留半成品资源、活动租约未释放，均视为缺陷。

## 三、注册

运行 `powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1"`，在菜单输入 `1`。

普通流程：

1. 程序自动查找已经打开且可识别的慧策通 Chrome。
2. 找到时默认“使用已打开的慧策通”；未找到时默认“自动启动新的 Chrome”。
3. 自动启动时程序自动寻找 `chrome.exe`、分配未占用本机端口并创建 F 盘配置目录。
4. 资源名称直接回车时自动生成 `慧策通端口-端口号`。
5. 平台、页面地址、页面匹配规则、登录页规则、启用状态由慧策适配器提供；备注默认留空。
6. 注册成功后程序自动检查，并提供“立即打开慧策通 / 再次检查 / 返回菜单”。

普通用户不需要理解或输入 CDP、URL Pattern、Login Pattern、ConnectOnly、Launch 等内部术语。只有选择“高级设置”或使用机器命令时才会接触技术参数。

正确结果：返回真实资源编号并保存真实初始状态。未监听时应显示“不可连接”和“登录状态未知”，不得伪造已连接或已登录；若端口被非 CDP 服务占用，必须拒绝注册。

主机安全边界：

- 本机使用 `127.0.0.1`、`localhost` 或 `::1`。
- ConnectOnly 远程登记只接受明确的私网、链路本地或 IPv6 ULA IP，不接受 DNS 主机名和公网 IP。
- 远程资源只做状态读取；第一阶段 Open 禁止控制远程 CDP。

## 四、检测

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Check -ResourceId HCP-XXXXXXXX
```

检测顺序：

1. TCP 是否可连接。
2. 端口是否存在监听进程。
3. HTTP 是否响应。
4. `/json/version` 是否为 Chromium 调试接口。
5. `/json/list` 是否包含真实页面。
6. 页面是否匹配登记的慧策规则。
7. 是否明确处于登记的登录页。

验收原则：不能把监听、HTTP、浏览器或页面正确当成已登录。只有慧策登录适配器的实时鉴权续接与只读 API 探针成功，才允许返回 `已登录 / high / logged-in-api-ready`；否则按真实证据返回未登录、失效、检测失败或未知。

## 五、打开

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId HCP-XXXXXXXX -TimeoutSeconds 20
```

执行顺序：

1. 按资源编号读取配置。
2. 拒绝停用资源。
3. 建立短期操作租约。
4. 检查端口监听与冲突。
5. 连接已有 CDP 浏览器，或按 Launch 配置启动浏览器。
6. 等待真实 `/json/version` 响应。
7. 页面不存在时，通过 CDP `PUT /json/new?{url}` 打开登记页面。
8. 再次读取 `/json/list` 回查页面。
9. 保存真实状态、审计和脱敏日志。
10. 释放操作租约。

成功标准：浏览器调试接口真实可访问；登记了平台规则时，页面必须真实匹配。登录状态可以是未知，但不得伪造已登录。

失败处理顺序：若浏览器由本次 Open 启动，先按启动 PID、子进程、调试端口和 F 盘配置目录精确回收本次进程，再保存失败后的真实端口状态，最后释放租约。本程序不会关闭连接前已经存在的用户浏览器。

## 六、编辑、启停与删除

编辑：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Edit -ResourceId HCP-XXXXXXXX
```

启停：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Enable -ResourceId HCP-XXXXXXXX
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Disable -ResourceId HCP-XXXXXXXX
```

删除：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Delete -ResourceId HCP-XXXXXXXX
```

编辑、启停和删除前都会检查操作租约、活动监听进程和 running 登录检测任务。删除需要准确输入：

```text
删除 HCP-XXXXXXXX
```

删除资源不会删除审计记录、日志或用户浏览器配置目录。

占用检查在进入写锁前可快速拒绝，并在写锁内基于最新资源、租约和监听进程再次确认，防止 Edit/Delete 与 Open 并发穿透。

## 七、失败处理

- `端口占用`：关闭错误进程或更换端口，再重新检测。
- `浏览器未启动`：检查浏览器路径、连接方式和 F 盘配置目录权限。
- `调试接口不可访问`：确认浏览器确实带远程调试参数启动。
- `平台页面错误`：核对真实页面地址与平台匹配规则。
- `登录状态未知`：由用户在浏览器中确认，不能把未知改写为成功。
- `打开超时`：确认浏览器版本、配置目录、端口和安全软件后重试。

## 八、用户真实验收

按 `tests\real-validation-record.md` 的顺序执行。每项必须粘贴实际输出、填写实际结果和是否通过。没有执行的项目保持“待用户真实测试”。

开发回归命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-business-regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-login-state-regression.ps1
```

回归会在 `data\test-runs` 下创建唯一 F 盘隔离目录，并使用真实 TCP 端口、真实监听进程和现场可用的真实 Google Chrome 验证失败回收；临时 Profile 仍置于独立的 F 盘 Profile 根。登录专项回归会使用测试拥有的 F 盘 Profile 真实打开慧策登录页，并在完成后精确回收本轮 Chrome；不会伪造慧策页面、鉴权证据或登录结果。
## 2026-07-29 运行依赖与检测收口

SQLite 服务只接受 F 盘 Python 解释器：优先 `BSCLAW_PYTHON_PATH`，其次项目 `tools\python\python.exe`，最后仅接受 PATH 中实际位于 F 盘的 `python.exe`。若没有 F 盘解释器，程序明确失败，不会使用 C 盘解释器或创建空库。

登录检测任务由 SQLite `login_detection_tasks` 唯一记录，状态使用 `running/completed/failed/cancelled`；启动后必须写入真实 worker PID。每个 CLI 操作先执行超时 reaper，超时进程被回收、任务和运行状态收口并写入 SQLite 审计。删除/编辑/打开在检测任务活动期间拒绝；取消会等待进程退出并设置退避时间。
