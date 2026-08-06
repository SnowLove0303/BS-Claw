# 下一轮阻断项：活动 Chrome 会话与资源登记脱节

## 现场事实

本轮回归期间收到用户提供的只读现场证据：Google Chrome PID `23368`，CDP `127.0.0.1:49841`，Profile `F:\\XIANGMU\\BS Claw\\_portmanager-profiles\\huice-49841`，页面标题“旺店通 | 慧策”，URL `erp.huice.com/#/app/base/home`。未读取 Cookie、Token、密码或完整授权头。

## 当前结论

该会话在当前 SQLite List 中没有对应资源记录，属于“已有会话未登记/资源登记脱节”阻断项。本轮不自动登记、不生成新 Profile、不宣称已修复，避免把未知会话错误映射为新的未登录资源。

## 下一轮必须验证与修复

1. 同一 `resourceId` 固定绑定 `host+port+browserProfileDirectory`；重复 Open 只复用存活端口和 Profile，失效后仍使用同一 Profile Launch。
2. 发现活动 Chrome、Profile 锁或其他资源占用时，明确提示“已有会话未登记/资源占用”，禁止静默创建新会话。
3. ConnectOnly 发现已有慧策端口时，持久化可复用该执行环境的最小元数据（不保存敏感值）。
4. Open 成功后进入 `loginDetectionState=检测中`，由独立 watcher/轮询在不依赖下一次 CLI 调用的情况下同步 SQLite。
5. `authenticatedEvidenceRules` 当前为空，只能返回“登录状态未知”；真实鉴权规则和真实登录成功证据仍未验证。
6. 真实回归路径：Open → 手动登录 → 后台检测状态变化 → 关闭/重开仍复用同一端口、Profile 和会话；不同 `resourceId` 必须隔离。

## 证据与回滚

- 本轮完整回归：`data\\test-runs\\business-regression-20260729-092508-092382a76c1f40bea8f9d3c1bb352d68`，20/20 通过；真实登录成功为未验证。
- 上述活动会话信息来自用户只读观察，未写入运行数据库。
- 回滚：恢复本轮修改前的工作树文件；不删除运行产物，不改动 `BS Claw\\System`。

## 本轮收口证据补充

- 最新完整业务回归：20/20，退出码 0；目录为 `data\\test-runs\\business-regression-20260729-092508-092382a76c1f40bea8f9d3c1bb352d68`。
- 最新干净环境静态门禁：7/7，退出码 0；目录为 `data\\test-runs\\static-validation-20260729-093247-d441e50001b84244b2e415b5a3abe0ad`。
- 正式 SQLite 已执行 migration 1–19，`PRAGMA integrity_check` 返回 `ok`；List 读取为空数组且退出码 0。
- 真实登录成功、会话复用与后台 watcher 尚未验证，不能据此判定底座完成。
