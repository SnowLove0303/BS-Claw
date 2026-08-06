# 后续复测要求

修复 BF-P2-008、BF-P2-009 后，必须重新执行：启用、停用、详情回查、审计日志 action、operationStatus、lastError 清理和重启后状态读取。

真实环境复测仍需覆盖：真实 Chromium/CDP 连接、慧策页面打开、登录状态未知边界、Launch 启动失败、超时回收、租约释放、并发 Open/Edit/Delete 和活动监听进程保护。
