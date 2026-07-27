# BSClaw Project Memory

## 固定路径

源码根目录：

`F:\XIANGMU\BS Claw\System`

远端仓库：

`https://github.com/SnowLove0303/BS-Claw`

## 当前边界

BSClaw 当前只包含 Electron + TypeScript + React/Vite 的最小 Windows 应用壳。

- 单 BrowserWindow。
- 单 Renderer。
- 空 preload，不暴露 Node 或 IPC 能力。
- 无数据库、HTTP 服务、后台任务、定时器、网络请求和业务入口。
- UI 只显示 BSClaw 品牌外壳，不得创建未接入能力的菜单、按钮或占位页面。

## 开发规则

一、依赖、缓存、构建、日志和运行数据必须位于 F 盘项目目录。

二、Renderer 保持 `nodeIntegration: false`、`contextIsolation: true`、`sandbox: true`。

三、新功能必须先明确真实需求、输入输出、权限、失败路径和验收方式；功能完成前不得增加 UI 入口。

四、不得加入 mock、sample、虚拟数据、假状态或调试信息。

五、主进程只负责 Electron 生命周期、窗口和运行路径；业务逻辑不得堆入 `src/main/index.ts`。

六、涉及打包时必须关闭旧进程，生成最新 EXE 后真实启动并核对运行路径。
