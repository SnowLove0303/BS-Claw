# 选品加入分销垂直案例技术实现记录

时间：2026-08-02

线程角色：技术执行开发线程。本文只记录实现、开发自检和真实执行事实，不作为需求与审计线程的一至四级审计结论、用户测试结论或发布放行结论。

## 一、读取与执行基线

- 任务记录：`changes/dispatch-selection-mainline-correction-20260802.md`、`changes/dispatch-selection-join-distribution-vertical-case-20260802.md`
- 项目根：`F:\XIANGMU\BS Claw`
- 本模块：`F:\XIANGMU\BS Claw\SelectionModule-Phase1`
- 分支：`feature/selection-module-phase1`
- 边界：未修改 BSClaw-Local、PortManager-Phase1、HuiceLoginAgent；未直接读写 PortManager SQLite；未输出或保存凭据、Cookie、Token、完整授权头或 Profile 内容；未提交、未推送、未打包。

## 二、修改文件与模块

- `scripts/cdp_fetch.py`
  - 新增受控 CDP 只读/写入调用器。
  - 在 ERP 页面上下文内执行 `/scmapi/api/admin/distribution/login/auth`，令 token 只留在页面运行时。
  - 请求慧策 `/scmapi` 接口时仅返回脱敏响应摘要、分页摘要和必要业务字段。
  - 修复 Windows PowerShell stdin UTF-8 BOM 兼容：使用 `utf-8-sig` 解码。
- `modules/Selection.HttpConnector.psm1`
  - 增加 `cdp-fetch` invokeMode，统一由 ResourceContext.port 连接本地 CDP。
  - HTTP connector 不接收、不输出 token/cookie/authorization。
- `modules/Selection.Candidates.psm1`
  - `candidate.acquire` 接入真实慧策候选读取。
  - 默认真实只读候选入口：`/scmapi/api/admin/distributor/goods/list`。
  - 支持按传入 httpRequest 读取供应商商品候选：`/scmapi/api/admin/distributor/supplier/goods/list`。
- `modules/Selection.Rules.psm1`
  - `candidate.filter` 支持版本化规则、字段存在、等值过滤、去重、命中/淘汰原因。
- `modules/Selection.Actions.psm1`
  - `selection.execute` 接入真实写入、幂等键、授权门禁、写后精确回查。
  - 写入后对回查做短轮询；仍未命中则进入 `RECOVERY_REQUIRED`，禁止盲重试写入。
  - 结果只保留 `writeSummary/readbackSummary/readbackMatch`，不保存完整回查商品列表。
- `modules/Selection.Recovery.psm1`
  - `Recover` 能对 `selection.execute` 的未知结果执行只读回查并收口任务状态。
  - 恢复结果只保留摘要和精确命中商品，不保存完整商品列表。
- `module.manifest.json`、`selection-module.manifest.json`、`adapter/bsclaw-selection-adapter.json`
  - 声明 `candidate.acquire`、`candidate.filter`、`selection.execute`，资源策略均为 `same-resource-exclusive`，写入 action 要求授权、幂等和 readback-before-retry。

## 三、真实资源事实摘要

事实来源：BSClaw-Local `PortManagerAdapter` 调用 PortManager 公共 JSON/List，不读 SQLite。

- 资源：慧策通端口-59404
- resourceId：仅记录尾号 `E855`
- port：59404
- state：可用
- connection/browser：浏览器可连接
- page：平台页面正确
- login：已登录
- api：logged-in-api-ready
- confidence：high
- freshness：fresh
- checkedAt：2026-08-02T19:17:33.8451577+08:00
- occupancyActive：false
- leaseActive：false

## 四、真实 API 与字段固化

字段来源：Feishu/任务资料、Pynes 代码参考、本次真实慧策响应三方对照。

参考实现：
- 本地参考仓库：`F:\XIANGMU\BS Claw\_reference\pynes-desktop`
- 外部来源：[SnowLove0303/pynes-desktop](https://github.com/SnowLove0303/pynes-desktop)
- 参考点：`src/connectors/huice-wdt/client.ts` 中 `joinDistribution` 使用 `POST /api/admin/distributor/selection`，body 为 `supplierShopId + paramList[{ supplierGoodsId, itemList }]`。

本次真实环境固化的 BSClaw 路径：

- 登录刷新：`POST /scmapi/api/admin/distribution/login/auth`
- 已分销商品列表：`POST /scmapi/api/admin/distributor/goods/list`
- 供应商商品候选：`POST /scmapi/api/admin/distributor/supplier/goods/list`
- 加入分销：`POST /scmapi/api/admin/distributor/selection`

候选/回查关键字段：

- `goodsId`
- `supplierGoodsId`
- `supplierShopId`
- `supplierCompanyName`
- `goodsName`
- `outerGoodsSn`
- `categoryName`
- `cooperationStatus`
- `createTime`
- `updateTime`
- `skus/itemList`

## 五、真实候选、规则和目标商品

只读候选读取：

- 已分销列表读取：20 条/页，真实返回 20 条候选样本。
- 供应商商品列表读取：`supplierShopId=263903`，真实返回 20 条候选样本。
- 供应商候选示例：`supplierGoodsId=967545/967546/967548` 等。

规则执行：

- 规则版本：`real-goods-list-v1`
- 规则内容：字段存在、`cooperationStatus=70`、按 `supplierGoodsId` 去重。
- 已分销列表规则结果：selected 20，rejected 0。

本次垂直案例目标：

- supplierShopId：263903
- supplierGoodsId：952251
- goodsName：`【优形】沙拉鸡胸肉100g*9袋赠新品尝鲜装共4袋（口味随机不指定）`
- itemList：`[44755626]`
- 写入前精确回查：已分销列表前 10 页 220 条，未命中 `supplierGoodsId=952251`。

## 六、加入分销 Action 与精确回查

写入 Action：

- taskId：`selection-task-ca9de5210fa84f28ac29faf163e69f7f`
- action：`selection.execute`
- idempotencyKey：`bsclaw-selection-join-952251-263903-20260802`
- 请求路径：`POST /scmapi/api/admin/distributor/selection`
- 请求体结构：`supplierShopId=263903`，`paramList=[{supplierGoodsId=952251,itemList=[44755626]}]`
- 授权来源：用户正式任务派发中允许在授权、隔离或可回滚真实商品上执行加入分销；未记录凭据。

即时写后状态：

- writeStatus：HTTP_OK
- immediate readback：HTTP_OK，但首次精确回查未命中，按设计进入 `RECOVERY_REQUIRED`
- 未执行二次写入，按 readback-before-retry 进入恢复。

恢复回查：

- Recover 入口：`selection-module.ps1 -Action Recover -TaskId selection-task-ca9de5210fa84f28ac29faf163e69f7f`
- status：SUCCEEDED
- phase：RECOVER
- readbackSource：`/scmapi/api/admin/distributor/goods/list`
- readbackItemCount：221
- 精确命中：
  - supplierGoodsId：952251
  - distributorGoodsId/goodsId：204897
  - supplierShopId：263903
  - createTime：2026-08-02 19:08:33

## 七、状态、错误、租约和恢复策略

- 成功路径：`candidate.acquire -> candidate.filter -> selection.execute -> Recover/readback -> SUCCEEDED`
- 写入未知路径：写入返回后若 readback 未命中，状态为 `RECOVERY_REQUIRED`，下一步只允许 Recover/readback，不盲重试写入。
- 恢复路径：Recover 使用原任务 readbackRequest/readbackExpect 重新读取分销列表；命中后将任务状态收口为 `SUCCEEDED`。
- 资源释放/占用：本轮技术路径未直接创建 PortManager 租约；最终 PortManager 公共 List 显示 `occupancyActive=false`、`leaseActive=false`。
- 取消/超时/父进程退出：模块保留 `Cancel/Recover` 指令化入口，本次垂直案例没有触发取消、关闭窗口、超时或父进程退出。

## 八、代码级验证命令与输出摘要

静态验证：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\XIANGMU\BS Claw\SelectionModule-Phase1\tests\run-static-validation.ps1" -ModuleRoot "F:\XIANGMU\BS Claw\SelectionModule-Phase1"
```

输出摘要：`ok=true`，PowerShell parser errors=0，JSON manifest count=4，Discover=`DISCOVERED`，空资源 Preflight=`AUTH_REQUIRED`。

Python 语法：

```powershell
python -B -m py_compile "F:\XIANGMU\BS Claw\SelectionModule-Phase1\scripts\cdp_fetch.py"
```

输出摘要：通过，无输出。

Git 空白检查：

```powershell
git -C "F:\XIANGMU\BS Claw\SelectionModule-Phase1" diff --check
```

输出摘要：退出码 0；仅提示 `manifest.json` 未来 Git 触碰时 LF/CRLF 转换。

自动发现：

- BSClaw-Local `ModuleRegistry` + `BSCLAW_MODULE_ROOTS=F:\XIANGMU\BS Claw\SelectionModule-Phase1`
- selectionDiscovered：true
- selectionValid：true
- actionIds：`candidate.acquire`、`candidate.filter`、`selection.execute`
- entryPath：`F:\XIANGMU\BS Claw\SelectionModule-Phase1\selection-module.ps1`

## 九、可复用工作流标准 V1

1. 业务目标输入：用户/Codex 表达“选品加入分销”目标。
2. 调度识别：BSClaw-Local 选择 `huice-selection-phase1 / selection.execute`。
3. 资源绑定：调度层通过 PortManager 公共资源事实源选择已启用、API-ready、未占用资源。
4. 预检：端口、CDP、Profile、页面、登录、API-ready、权限、占用、租约均通过后继续。
5. 候选读取：模块通过受控 CDP connector 读取真实候选，不读取凭据或 Profile。
6. 规则筛选：使用版本化规则生成 selected/rejected 和原因。
7. 写入 Action：必须具备 `actionContractVerified=true`、授权范围、幂等键、请求体和 readbackExpect。
8. 写后回查：按 `supplierGoodsId + supplierShopId` 精确回查分销列表/详情。
9. 未知结果：写入返回但回查未命中时进入 `RECOVERY_REQUIRED`，只读 Recover，不自动重写。
10. 成功收口：命中真实分销商品后落地 `SUCCEEDED`、脱敏摘要、命中对象和下一步。
11. 资源收口：调度层释放租约/锁，资源事实源回查占用 false。

## 十、未完成项与需审计线程继续验证

- 本记录不替代正式用户入口、业务测试、回归测试或一至四级审计。
- 本次垂直案例没有触发验证码/外部风控、取消、超时、父进程退出路径；这些仍需由需求与审计线程按矩阵独立执行。
- 本次真实写入只执行一次；没有为了验证幂等而重复写入同一商品，避免对真实业务数据造成额外影响。
- 当前 `tests/run-static-validation.ps1` 直接运行时需显式传 `-ModuleRoot`；未传时 PowerShell 参数默认值会取不到脚本路径。已在自检中使用显式参数。

## 十一、回滚点与恢复方式

当前仓库尚无初始提交，不能用 Git 提交点作为正式回滚基线。建议需求与审计线程接收后先建立独立初始提交或备份点。

代码回滚方式：

1. 使用 `git -C "F:\XIANGMU\BS Claw\SelectionModule-Phase1" status --short` 确认本轮文件。
2. 在未提交状态下，仅按文件级差异恢复本轮新增/修改文件；不得对父目录执行清理。
3. 如需撤销真实业务写入，应由慧策业务侧按正式可回滚流程处理，本线程不直接删除真实分销商品。

业务恢复方式：

- 对未知写入结果只执行 readback/recover，不盲重试。
- 对已加入分销商品的反向处理需业务授权和正式回查，不属于本轮自动操作范围。
