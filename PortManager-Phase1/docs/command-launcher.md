# BS Claw 快捷启动

## 解决的问题

安装一次后，可以在任意 PowerShell 工作目录直接输入以下任一命令，打开 BS Claw Python 本地层中文菜单：

```powershell
BS Claw
bsclaw
```

两个命令都调用同级 `BSClaw-Local`。本地层只读取端口管理正式 JSON 入口，不复制或重写端口管理逻辑；菜单中的“打开端口管理”继续调用正式根入口 `port-manager.ps1`。

## 安装

在模块当前实际位置执行一次：

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\install-bsclaw-command.ps1"
```

关闭并重新打开 PowerShell，然后输入：

```powershell
BS Claw
```

预期看到 `BS Claw 本地层` 中文菜单。输入 `8` 可进入原端口管理，输入 `0` 应安全退出。

## 迁移或移动目录

快捷命令使用相对路径发现同级 `BSClaw-Local`。把项目复制到新的 F 盘位置后，应保持 `BSClaw-Local`、`PortManager-Phase1` 和 `HuiceLoginAgent` 同级，再在新位置重新执行安装脚本。安装脚本会增加新路径且不会重复增加同一路径。确认新入口可用后，可在旧位置执行卸载。

## 卸载

```powershell
powershell -NoP -EP Bypass -File "F:\XIANGMU\BS Claw\PortManager-Phase1\install-bsclaw-command.ps1" -Uninstall
```

卸载只移除本模块的命令目录 PATH 项，不删除代码、数据库、资源、Profile、日志或登录状态。每次安装或卸载前，原用户 PATH 都备份在模块的 `data\command-backups` 目录。

## 通过与失败标准

通过：

- 在非项目目录输入 `BS Claw` 或 `bsclaw` 都能看到同一 Python 中文菜单。
- 输入 `0` 后退出码为 0。
- 输入 `8` 能打开原端口管理，原绝对路径入口仍可用。
- 重复运行安装脚本不会重复增加 PATH。

失败：

- PowerShell 提示找不到 `BS` 或 `bsclaw`：重新打开 PowerShell；若仍失败，重新运行安装脚本。
- 提示找不到 Python 本地层：模块目录未保持同级或文件不完整，应恢复目录结构后重试。
- 提示找不到 F 盘 Python：按提示设置当前 PowerShell 的 `BSCLAW_PYTHON_PATH`，或放到 `PortManager-Phase1\tools\python\python.exe`。
- 输入 `BS` 但没有输入 `Claw`：程序只显示 `Usage: BS Claw`，不会启动其他程序。
