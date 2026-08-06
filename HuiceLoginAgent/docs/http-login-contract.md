# HTTP login contract

## 冷启动账号登录

慧策官网当前登录组件使用以下同源顺序：

1. `POST /open/tm/unified-login/v5/login/getPlatformRiskKeysByTenant`
   - 请求只包含 `tenantId`。
2. `POST /open/tm/unified-login/v5/login/password`
   - 账号路径包含 `mobileAccount=false`、`tenantId`、`account`、`password`、`deviceId`、`clientType=WEB`、`eid`、`vid`、`oauthBindKey` 和 `authKey`。
   - 未发生图形验证码时省略 `captchaId/authCode`，不得发送空验证码字段。

成功响应为 HTTP 2xx 且业务 `code=0`。服务端在同一浏览器会话中建立 `X-HC-TOKEN`；随后进入产品地图，再由既有逻辑进入 ERP。常见业务码按状态分类：`200009/200016` 为凭据失败，`100002/100004` 为图形验证，`100012` 为安全验证，`100020` 为密码更新，`100070` 为手机号初始化。不得把这些状态统一包装成超时。

本契约来自 2026-07-30 实时加载的慧策官网 `LoginComponent` 与共享组件资源。`POST /scmapi/api/admin/distribution/login/auth` 不是账号密码登录，而是进入 ERP 后的会话续接。

## ERP 会话续接与探针

进入 ERP 后发送同源 `POST /scmapi/api/admin/distribution/login/auth`。仅当 `error == 0` 且 `content.token` 非空时写回当前页面内存/Local Storage，并立即执行 goods overview 只读探针。Token 值不离开页面上下文。

## 安全边界

密码不进入进程参数、环境变量、日志、SQLite、文档或临时文件。PowerShell `Read-Host` 是最终用户路径和发布主验收入口；正式集成由 PortManager 的 CredentialRef/受控凭据提供器传入一次性内存对象。重定向 stdin 仅验证受控传输兼容性，不作为用户路径的权威证据。发布实现不包含浏览器表单填写或点击的竞争登录实现；`Login` 只调用当前页面上下文内的同源 HTTP 登录链。
