# 端口管理推广候选人工测试

本文分为两层：普通用户应优先从端口管理中文菜单进入，查看列表后按序号选择资源；下方带 `-ResourceId` 的命令仅是开发/审计接口，用于机器复验，不要求普通用户复制或记忆资源编号。

## 1. 查看端口

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action List -OutputFormat Json -NonInteractive
```

通过：返回 `success=true`，资源列表可读；普通菜单显示名称、端口和状态，不要求用户输入内部编号。

## 2. 打开并复用慧策资源

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action Open -ResourceId HCP-E1880AE9 -TimeoutSeconds 20 -OutputFormat Json -NonInteractive
```

通过：复用 53392 和登记 Profile，不创建第二个 Profile；返回阶段耗时；最终无活动租约。

## 3. 检查登录与 API

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action HuiceCheck -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
```

通过：真实可用会话返回 `logged-in-api-ready`，且 PortManager Check/List 同步显示“已登录 / high”。

## 4. 再次复用

重复步骤 2 和 3。通过：ResourceId、端口、Profile 和已运行 Chrome 主 PID 不变。

## 5. 未登录时输入账号

不要破坏正式资源。先创建独立登录测试环境：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action CreateLoginTestProfile -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
```

用返回的新 ResourceId 执行：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action HuiceLogin -ResourceId HCP-XXXXXXXX
```

只有真实未登录页才依次输入企业账号、用户账号和不回显密码。需要验证码、滑块、短信、二维码或二次确认时，只在同一登记 Chrome 完成平台要求的外部验证，然后重新执行同一 Login 命令；不要在 Chrome 中重新输入账号密码、点击普通登录表单或复制 Token/Cookie。通过：同源 HTTP 登录接口与只读探针都成功，状态写回 PortManager。此步骤必须由用户持有真实账号执行。

## 6. 只看缓存，不删除

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action CachePlan -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
```

通过：`executeMode=dry-run`，文件大小不下降。清缓存不等于退出登录。

## 7. 部署前盘点

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action StorageAudit -OutputFormat Json -NonInteractive
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\port-manager.ps1" -Action DeploymentCleanPlan -ResourceId HCP-E1880AE9 -OutputFormat Json -NonInteractive
```

通过：区分代码、数据库事实源、测试产物、运行数据、Profile 缓存和非缓存数据，且不删除任何内容。

## 失败反馈

只提供：命令、退出码、`errorCode`、中文 `message`、`nextAction`、ResourceId、端口、是否新开窗口、是否改变 Profile。禁止提供密码、Token、Cookie、验证码或完整授权头。

以下任一项为失败：JSON 混入提示文字；新建未登记 Profile；旧成功状态覆盖真实失败；租约不释放；普通 List/Check/Open 隐式清理；数据库 integrity 不是 `ok`。

