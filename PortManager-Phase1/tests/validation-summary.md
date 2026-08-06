# Codex 验证摘要

复验日期：2026-07-28（Asia/Shanghai）

## 已真实执行

1. 使用 Windows PowerShell 5.1.26100.8875 解析全部 `.ps1` / `.psm1`：无语法错误。
2. 解析适配清单和源码基线端口 JSON：有效。
3. 启动根入口并执行空数据 `List` JSON：退出码 0，返回真实空数组。
4. 启动中文菜单并安全退出：0-8 菜单、注册入口、全部检查入口存在。
5. 检查 24 个必需交付路径，包括注册、登录、状态、持久化、Chrome 生命周期和输出模块。
6. 检查主系统：工作树干净，分支 `agent/bootstrap-bsclaw`，HEAD `b1c668078d8959793ba2f4698efc751b9e315567`。
7. 完整业务回归：20 项通过，0 项失败。
8. 针对性首次注册向导：真实创建隔离资源、自动启动 Chrome、打开慧策登录页并判定“未登录”；测试后残留进程 0、租约 0。
9. 登录专项回归：10 项通过，0 项失败；真实登录页、真实现有慧策页面未知边界、关闭后状态更新和敏感信息扫描均已执行。

复验命令：

```powershell
Set-Location 'F:\XIANGMU\BS Claw\PortManager-Phase1'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-static-validation.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-business-regression.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run-login-state-regression.ps1
```

## 未执行且不得描述为通过

- 未使用用户真实账号执行鉴权或业务操作。
- 未验证真实“已登录”、登录失效和自动登录。
- 未修改、编辑、启停或删除用户真实资源。
- 未接入 BS Claw 主系统。

这些项目必须按 `real-validation-record.md` 由用户使用真实环境填写实际输出后才能判定。本次状态是“开发修复及自动化回归完成，等待用户人工复测”，不是业务审计通过。

## 现场问题与处理

- Windows PowerShell 的 `Process.StandardInput` 首行 BOM 曾造成自动回归误读菜单。应用已统一重定向输入读取，回归启动器改用 F 盘无 BOM 输入文件；RG-015 与 RG-019 已通过。
- 静态验证曾创建隔离目录但未把环境变量传给子进程，导致只读 List 指向默认 runtime。已修正为每次唯一 F 盘目录并向所有子进程传递；用户真实状态文件哈希与最后写入时间未变化。
- 现场没有 PSScriptAnalyzer，未为此向 C 盘下载模块；使用原生解析器、实际进程启动和完整业务回归替代。
