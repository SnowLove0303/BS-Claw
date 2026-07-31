# BS Claw 快捷启动

## 解决的问题

安装一次后，可以在任意 PowerShell 工作目录直接输入以下任一命令，打开端口管理中文菜单：

```powershell
BS Claw
bsclaw
```

两个命令都调用当前模块的正式根入口 `port-manager.ps1`，不会复制或维护第二套端口管理程序。

## 安装

在模块当前实际位置执行一次：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\install-bsclaw-command.ps1"
```

关闭并重新打开 PowerShell，然后输入：

```powershell
BS Claw
```

预期看到 `BSClaw 慧策通端口管理（第一阶段）` 中文菜单。输入 `0` 应安全退出。

## 迁移或移动目录

快捷命令使用相对路径发现同一模块内的正式入口。把项目复制到新的 F 盘位置后，在新位置重新执行安装脚本即可；安装脚本会增加新路径且不会重复增加同一路径。确认新入口可用后，可在旧位置执行卸载。

## 卸载

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\install-bsclaw-command.ps1" -Uninstall
```

卸载只移除本模块的命令目录 PATH 项，不删除代码、数据库、资源、Profile、日志或登录状态。每次安装或卸载前，原用户 PATH 都备份在模块的 `data\command-backups` 目录。

## 通过与失败标准

通过：

- 在非项目目录输入 `BS Claw` 或 `bsclaw` 都能看到同一中文菜单。
- 输入 `0` 后退出码为 0。
- 重复运行安装脚本不会重复增加 PATH。
- 原绝对路径入口继续正常使用。

失败：

- PowerShell 提示找不到 `BS` 或 `bsclaw`：重新打开 PowerShell；若仍失败，重新运行安装脚本。
- 提示找不到 PortManager 入口：模块已移动或文件不完整，应在模块新位置重新安装。
- 输入 `BS` 但没有输入 `Claw`：程序只显示 `Usage: BS Claw`，不会启动其他程序。
