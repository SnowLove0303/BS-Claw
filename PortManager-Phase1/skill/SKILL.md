---
name: bsclaw-huice-port-manager-phase1
description: Use the standalone BSClaw phase-one PowerShell port manager to register, inspect, check, enable, disable, open, or delete a real Huice Chromium debugging port by resource ID.
---

# BSClaw 慧策通端口管理

## 使用边界

本 Skill 只调用 `F:\BS-Claw\PortManager-Phase1` 的独立 PowerShell 程序。

- 不修改或假定存在仓库中的 `System/` 应用壳。
- 不直接写死端口号；先取得 `HCP-XXXXXXXX` 资源编号。
- 不读取或保存 Cookie、Token、密码、授权头或浏览器存储。
- 不执行商品、订单、库存、铺货、价格、售后或其他慧策业务动作。
- 不把端口监听、浏览器连接或平台页面正确描述为已登录。
- 不自行配置或伪造鉴权规则；只有 HuiceLoginAgent 的实时鉴权续接与只读 API 探针同时成功，才能使用“已登录 / logged-in-api-ready”。
- `credentialRef` 只允许引用未来受控凭据存储；不得把账号密码、Cookie、Token 或授权头写入参数、JSON、日志或审计。
- 不对远程主机执行 Open；第一阶段 `/json/new` 和 `/json/activate` 只允许回环地址。

## 调用前检查

1. 确认用户给出了真实资源编号，或明确要求交互注册。
2. 打开浏览器属于有外部副作用的操作；向用户说明可能启动浏览器和新标签页。
3. 删除必须由用户确认准确文本 `删除 <ResourceId>`。
4. 若输出为 `登录状态未知`，如实返回，不得推断为已登录。
5. JSON 模式必须把 stdout 当作单一 JSON 文档解析；Edit 必须提供变更参数，Delete 必须提供确认文本。

## 常用命令

查看：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
```

检测：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Check -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
```

打开：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId HCP-XXXXXXXX -OutputFormat Json -NonInteractive
```

交互注册：

```powershell
powershell -NoP -EP Bypass -File "F:\BS-Claw\PortManager-Phase1\port-manager.ps1" -Action Register
```

交互注册使用业务向导：先自动发现已打开的慧策通 Chrome；未发现时默认自动启动 Google Chrome。端口、Chrome 路径、F 盘配置目录、慧策页面和识别规则由程序自动处理，资源名称可直接回车。注册后程序自动检查，并让用户选择立即打开、再次检查或返回菜单。只有用户明确选择“高级设置”时才输入技术字段。

## 结果判断

- `success=false`：操作失败，直接说明中文 `message`。
- `nextAction`：向用户提供一项下一步动作，不追加多个互相冲突的建议。
- `connectionStatus=端口冲突`：不可继续打开，先处理占用进程。
- `browserStatus=浏览器可连接`：只证明 CDP 可用。
- `pageStatus=平台页面正确`：只证明存在匹配页面。
- `loginStatus=未登录`：发现明确登录页。
- `loginStatus=已登录`：只有 HuiceLoginAgent 的实时 CDP 鉴权续接与只读 API 探针通过后才允许。
- `loginStatus=登录状态未知`：缺少独立鉴权证据，必须保留未知。
- `loginStatus=检测失败`：登录检测本身异常，不等同于未登录。
- `loginStatus=登录已失效`：历史真实已登录证据在复查中失效。
- `operationStatus=打开失败`：读取 `lastError`，确认本次浏览器进程和租约已清理后再决定是否重试。
- `currentOccupancy` 包含 `租约:`：资源正在被其他操作使用，不得并发编辑、删除或打开。

## 未来 BSClaw 接入

未来加载器读取 `adapter\bsclaw-port-adapter.json`，把 BSClaw 的任务、锁、确认、审计和结果状态映射到本模块。未完成映射前，不得把本目录声明为已安装 BSClaw 插件。
