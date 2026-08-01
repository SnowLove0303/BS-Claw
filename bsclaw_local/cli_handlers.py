from __future__ import annotations

import argparse
import time
from typing import Any

from .app_context import LocalApplication
from .parameter_loader import load_parameters
from .scheduler_models import (
    STATE_BLOCKED,
    STATE_CANCELLED,
    STATE_FAILED,
    STATE_TIMED_OUT,
    STATE_UNVERIFIED,
)
from .scheduler_store import SchedulerDataError


FAILED_STATES = {STATE_BLOCKED, STATE_FAILED, STATE_CANCELLED, STATE_TIMED_OUT, STATE_UNVERIFIED}
FINISHED_STATES = FAILED_STATES | {"成功", "等待人工处理"}


def handle_task(app: LocalApplication, args: argparse.Namespace) -> dict[str, Any]:
    action_name = f"task.{args.task_command}"
    try:
        data = _task_operation(app, args)
        success = _task_success(args.task_command, data)
        message, error_code, next_action = _task_messages(data, args.task_command)
        return task_envelope(action_name, success, data, message=message, error_code=error_code, next_action=next_action)
    except SchedulerDataError as exc:
        return task_envelope(action_name, False, None, message=str(exc), error_code="SCHEDULER_REQUEST_REJECTED", next_action="根据提示修正后重试")


def _task_operation(app: LocalApplication, args: argparse.Namespace) -> Any:
    operation = args.task_command
    if operation == "submit":
        _validate_timeout(args.timeout_seconds)
        return app.scheduler.submit(module_id=args.module_id, action=args.action, parameters=load_parameters(args), resource_id=args.resource_id, timeout_seconds=args.timeout_seconds)
    if operation == "status":
        return app.scheduler.status(args.task_id)
    if operation == "result":
        return app.scheduler.result(args.task_id)
    if operation == "list":
        return app.scheduler.list(max(1, min(args.limit, 200)))
    if operation == "cancel":
        return app.scheduler.cancel(args.task_id)
    if operation == "retry":
        return app.scheduler.retry(args.task_id)
    return app.scheduler.recover()


def _task_messages(data: Any, operation: str) -> tuple[str, str, str]:
    if isinstance(data, dict):
        return str(data.get("summary") or "任务操作成功"), str(data.get("errorCode") or ""), str(data.get("nextAction") or "")
    message = f"恢复处理 {len(data)} 条未完成任务" if operation == "recover" else f"读取到 {len(data)} 条任务记录"
    return message, "", "可继续查询任务详情"


def _task_success(operation: str, data: Any) -> bool:
    if operation in {"submit", "retry"} and isinstance(data, dict):
        return data.get("state") not in FAILED_STATES
    return True


def handle_service(app: LocalApplication, args: argparse.Namespace) -> dict[str, Any]:
    if args.service_command == "list":
        services = [item for item in app.module_registry.describe() if item.get("type") in {"service", "resource-service", "huice-resource-service"}]
        return task_envelope("service.list", True, services, message=f"发现 {len(services)} 个正式服务插件", next_action="可使用 service check 执行只读自检")
    try:
        _validate_timeout(args.timeout_seconds)
        task = app.scheduler.submit(module_id=args.service_id, action="service-check", parameters={}, resource_id="", timeout_seconds=args.timeout_seconds)
        task = wait_for_task(app, task, args.timeout_seconds)
        return task_envelope("service.check", task.get("state") == "成功", task, message=str(task.get("summary") or "服务自检结束"), error_code=str(task.get("errorCode") or ""), next_action=str(task.get("nextAction") or ""))
    except SchedulerDataError as exc:
        return task_envelope("service.check", False, None, message=str(exc), error_code="SCHEDULER_REQUEST_REJECTED", next_action="根据提示修正后重试")


def wait_for_task(app: LocalApplication, task: dict[str, Any], timeout_seconds: int) -> dict[str, Any]:
    task_id = str(task.get("taskId") or "")
    deadline = time.monotonic() + timeout_seconds + 5
    while task.get("state") not in FINISHED_STATES and time.monotonic() < deadline:
        time.sleep(0.2)
        task = app.scheduler.result(task_id)
    return task


def task_envelope(action: str, success: bool, data: Any, *, message: str, error_code: str = "", next_action: str = "") -> dict[str, Any]:
    return {"success": success, "action": action, "message": message, "taskId": data.get("taskId") if isinstance(data, dict) else None, "state": data.get("state") if isinstance(data, dict) else None, "data": data, "errorCode": error_code or None, "nextAction": next_action}


def _validate_timeout(value: int) -> None:
    if not 1 <= value <= 3600:
        raise SchedulerDataError("timeout-seconds 必须在 1 到 3600 之间。")
