# 第二次审计问题清单

## BF-P2-008 启用/停用的操作状态和审计动作被记录为编辑

- 所属功能：Enable、Disable。
- 触发条件：对已注册资源执行启用或停用。
- 预期：资源状态改变，同时 `lastStatus.operationStatus` 应准确记录启用/停用，审计记录 action 应区分 Enable/Disable。
- 实际：命令返回成功，资源 enabled 值正确变化，但状态中的 operationStatus 为“已编辑”，审计日志 action 记录为 Edit。
- 影响：用户和后续自动化无法准确判断最近一次真实操作；审计、回查、问题定位和流程统计会把启停误归类为编辑。
- 等级：BF-P2，一般功能缺陷级。
- 证据：隔离运行目录 `F:\XIANGMU\BS Claw\_audit-runtime\business-flow-20260727-06` 中 Enable/Disable 输出、`data\audit.jsonl` 和 `data\ports.json`。
- 当前状态：记录，不在本次审计中修改。

## BF-P2-009 启停后旧错误信息与“尚未检测”状态并存

- 所属功能：Enable、Disable 后的状态回查。
- 实际：启停会重置 HTTP/浏览器检测状态为“尚未检测”，但可能保留此前“连接超时”等 lastError，造成状态语义不一致。
- 影响：列表和详情可能同时显示“尚未检测”和旧失败原因，自动化或用户难以判断该错误是否属于当前状态。
- 等级：BF-P2，需在修复 BF-P2-008 时一并明确状态清理规则。
