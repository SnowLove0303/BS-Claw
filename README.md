# BS-Claw

本分支将端口资源底座与慧策登录代理作为同一份可复现交付：

- `PortManager-Phase1/`：资源、端口、Profile、租约、审计和当前状态真源。
- `HuiceLoginAgent/`：复用已有会话或在真实未登录时执行受控慧策同源 HTTP 登录，并用只读 API 探针确认状态。

两个目录必须保持同级。默认通过相对路径互相发现；非同级部署时只允许通过 `BSCLAW_PORT_MANAGER_ROOT` 或 `BSCLAW_HUICE_LOGIN_AGENT_ROOT` 显式指定 F 盘路径。

运行依赖为 Windows PowerShell 5.1+、Google Chrome 和带标准库 `sqlite3` 的 Python。Python 必须位于 F 盘：可放在 `PortManager-Phase1/tools/python/python.exe`，或通过进程级 `BSCLAW_PYTHON_PATH` 指定；仓库不会下载依赖或向 C 盘写缓存。

仓库不包含账号、密码、Token、Cookie、Credential 实值、SQLite 运行库、真实端口数据、Chrome Profile、缓存、日志、测试运行产物或审计证据。

当前慧策登录自动化状态的唯一正式枚举为 `huice-same-origin-http-login`。适配器、SQLite 写入、测试和设计文档必须保持同名。

用户验证见 [docs/manual-validation.md](docs/manual-validation.md)，迁入审计见 [docs/portmanager-login-migration-audit.md](docs/portmanager-login-migration-audit.md)。
