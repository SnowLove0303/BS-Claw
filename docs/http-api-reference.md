# 慧策 HTTP API 参考与固化规则

> 下列端点来自用户指定的 Feishu 文档读取结果和 Pynes 参考代码中的业务分层，用作待实现 connector 的参考索引；当前资料包不把它们标记为已在 BS Claw 中接通或已通过真实验证。

## 候选/商品读取参考

| 用途 | 参考路径 | 处理要求 |
|---|---|---|
| 热销候选 | `/openapi/api/admin/distributor/hotGoods/recommend` | 先核验请求条件、分页和响应对象 |
| 商品基础详情 | `/openapi/api/admin/goods/base/detail` | 作为商品详情/售后地址等权威读取源 |
| 供应商商品列表 | `/scmapi/api/admin/distributor/supplier/goods/list` | supplierShopId 和商品标识必须来自真实响应 |
| 选品列表 | `/scmapi/api/admin/distributor/selection` | 固化前先核验读写语义和幂等行为 |
| 分销商品列表 | `/scmapi/api/admin/distributor/goods/list` | 用于结果回查，不以写入返回代替 |
| 供应商列表 | `/scmapi/api/admin/distributor/my/supplier` | 用于资源/供应商候选约束 |
| 供应商数量 | `/scmapi/api/admin/distributor/countSupplier` | 仅作汇总，不替代列表事实 |
| 库存信息 | `/scmapi/api/admin/distributor/goods/stockInfo` | 核验商品/SKU 绑定和时间新鲜度 |
| 使用新供应商商品 | `/scmapi/api/admin/distributor/goods/supplier/useNew` | 写入前必须定义幂等与回查 |

## 发布/任务读取参考

| 用途 | 参考路径 | 当前处理 |
|---|---|---|
| 批量同步任务 | `/scmapi/api/admin/distributor/goods/publish/batch/sync/task` | 后续发布扩展，不纳入首个主干写入假定 |
| 是否上架 | `/scmapi/api/admin/goods/publish/isOnSale` | 作为状态回查参考 |
| 供应商商品发布详情 | `/scmapi/api/admin/supplier/goods/publish/detail` | 后续发布扩展 |
| 保存发布信息 | `/scmapi/api/admin/supplier/goods/publish/save` | 后续发布扩展，禁止提前调用 |
| 分销发布任务 | `/scmapi/api/admin/goods/distribution/publish/task` | 后续发布扩展 |
| 任务列表 | `/scmapi/api/admin/task/list` | 长任务结果回查参考 |
| 失败任务 | `/scmapi/api/admin/task/failed/list` | 失败分类与恢复参考 |
| 审核任务 | `/scmapi/api/admin/task/audit/list` | 需确认是否属于选品主链 |

## 认证与安全

文档中的 token、Cookie、X-HC-TOKEN、授权头和登录接口只允许通过安全凭据引用或正式登录流程使用。不得写入资料包、代码、日志或报告。登录 token 刷新路径 `/scmapi/api/admin/distribution/login/auth` 只能在真实契约核验后接入，不能据路径名称推断成功。

## API 固化前必须完成

请求方法、完整字段、必填/可选、分页、业务错误码、限流、幂等、成功判定、回查接口、失败补偿、supplierShopId 语义和真实响应样本必须逐项记录。Feishu 文档和真实响应冲突时，以当前平台真实响应和明确的版本记录为准，并登记冲突。
