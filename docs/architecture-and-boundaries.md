# 架构与模块边界

## 目标架构

选品模块采用与 PortManager 相同的本地技术路线：PowerShell 模块化脚本、SQLite 持久化、JSON manifest/adapter、可复现的 PowerShell 入口。它是独立模块仓库，通过公开契约接入 BSClaw-Local，不把源码硬合并进调度层或 PortManager。

## 依赖方向

```text
用户/Codex
   -> BSClaw-Local 统一调度
      -> 选品模块 manifest/adapter
      -> PortManager 公共资源服务
      -> HuiceLoginAgent 登录检测/授权边界
      -> 选品模块 HTTP connector
         -> 慧策 HTTP API
```

选品模块不得直接查询 PortManager SQLite；调度层不得维护第二套资源清单；PortManager 不得依赖选品模块才能完成自身资源管理。

## 计划目录

```text
SelectionModule-Phase1/
  selection-module.ps1          # 未来正式用户/指令入口
  scripts/                      # PowerShell 命令与参数边界
  modules/                      # 选品业务模块、HTTP connector、结果回查
  adapter/                      # 调度层公开适配器
  data/                         # 可再生运行数据；事实源需谨慎保护
  tests/                        # 指令化验证与隔离测试
  docs/                         # 需求、契约、执行规范、测试与回滚
```

本资料包当前不创建这些业务代码文件，目录仅作为后续实现边界。

## 持久化原则

SQLite 只保存任务快照、条件版本、外部任务引用、脱敏结果、恢复信息和必要索引。资源定义、端口配置、Profile、登录凭据和租约仍归属正式资源/登录服务；不可再生事实不得被清理任务删除。schema/migration 需在主干实现前单独确定并审计。

## HTTP connector 原则

所有外部调用必须经过模块 connector：统一超时、响应解析、错误归一化、脱敏、幂等键、读写分类和回查策略。写入调用默认不自动盲重试；遇到未知结果先回查。具体端点、字段和供应商上下文必须以实时文档与真实响应核验后固化。
