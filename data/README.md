# Runtime data

该目录只保存本机任务与检查记录。除本说明外，其余内容均为可再生运行数据，不进入 Git。

任务记录不包含密码、Cookie、Token、完整授权头、CredentialRef、Profile 内部路径或原始适配器响应。

- `task-records.jsonl` 是既有服务检查记录。
- `scheduler/tasks/*.json` 是统一调度任务的持久化状态。
- `scheduler/audit.jsonl` 是任务状态变化的脱敏审计记录。

调度数据不是 PortManager 资源事实源，也不能替代真实业务结果回查。
