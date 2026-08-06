from __future__ import annotations

import ctypes
from datetime import datetime
from typing import Any, Callable

from .models import now_iso
from .scheduler_models import (
    STATE_BLOCKED,
    STATE_CANCELLED,
    STATE_PREFLIGHT,
    STATE_RUNNING,
    STATE_TIMED_OUT,
    STATE_UNVERIFIED,
    STATE_WAITING_MANUAL,
    STATE_WAITING_LOGIN,
    STATE_WAITING_EXTERNAL_VERIFICATION,
    STATE_WAITING_VERIFY,
    TERMINAL_STATES,
    parse_iso,
)
from .scheduler_store import SchedulerDataError, SchedulerStore
from .scheduler_view import public_task
from .resource_mutex import ResourceMutex


class SchedulerRecovery:
    def __init__(self, store: SchedulerStore, start: Callable[..., dict[str, Any]]) -> None:
        self.store = store
        self.start = start

    def cancel(self, task_id: str) -> dict[str, Any]:
        task = self.store.load(task_id)
        if task["state"] in TERMINAL_STATES:
            raise SchedulerDataError("任务已经结束，不能取消。")
        task = self.store.transition(task, STATE_CANCELLED, stage="cancelled", summary="用户已取消任务", error_code="TASK_CANCELLED", next_action="无需继续执行", retryable=False, source="user", extra={"finishedAt": now_iso()})
        return public_task(task, include_result=True)

    def retry(self, task_id: str) -> dict[str, Any]:
        task = self.store.load(task_id)
        if not bool(task.get("retryable")):
            raise SchedulerDataError("当前失败不可安全重试。")
        if bool(task.get("businessWritesExecuted")):
            raise SchedulerDataError("任务可能已产生业务写入，必须先回查或人工确认。")
        task["attempt"] = int(task.get("attempt") or 1) + 1
        task["result"] = None
        task["verification"] = None
        task = self.store.transition(task, STATE_PREFLIGHT, stage="preflight", summary="任务重新进入预检", next_action="等待预检结果", retryable=False, source="retry")
        return self.start(task, already_preflight=True)

    def recover(self) -> list[dict[str, Any]]:
        recovered: list[dict[str, Any]] = []
        now = datetime.now().astimezone()
        for task in self.store.list(200):
            state = task.get("state")
            if state in TERMINAL_STATES:
                continue
            deadline = parse_iso(task.get("deadlineAt"))
            if deadline and deadline.astimezone() <= now:
                if task.get("resourceId"):
                    ResourceMutex.reclaim_if_stale(
                        self.store.root, str(task.get("resourceId"))
                    )
                task = self.store.transition(task, STATE_TIMED_OUT, stage="recovery", summary="程序重启后确认任务已超过截止时间", error_code="TASK_DEADLINE_EXCEEDED", next_action="确认没有业务写入后再决定是否重试", retryable=not bool(task.get("businessWritesExecuted")), source="recovery", extra={"finishedAt": now_iso()})
            elif state in {STATE_WAITING_MANUAL, STATE_WAITING_LOGIN, STATE_WAITING_EXTERNAL_VERIFICATION}:
                owner_pid = int(task.get("ownerPid") or 0)
                if owner_pid and not process_is_active(owner_pid):
                    if task.get("resourceId"):
                        ResourceMutex.reclaim_if_stale(
                            self.store.root, str(task.get("resourceId"))
                        )
                    task = self.store.transition(
                        task,
                        STATE_CANCELLED,
                        stage="recovery",
                        summary="人工介入所属进程已退出，等待状态已清理",
                        error_code="PARENT_PROCESS_EXITED",
                        needs_manual=False,
                        next_action="重新从正式入口发起操作",
                        retryable=True,
                        source="recovery",
                        extra={"finishedAt": now_iso()},
                    )
                    recovered.append(public_task(task, include_result=False))
                continue
            elif state in {STATE_RUNNING, STATE_WAITING_VERIFY}:
                if process_is_active(
                    int(task.get("workerPid") or 0),
                    task.get("workerProcessStartToken"),
                ):
                    continue
                if task.get("resourceId"):
                    ResourceMutex.reclaim_if_stale(
                        self.store.root, str(task.get("resourceId"))
                    )
                task = self.store.transition(task, STATE_UNVERIFIED, stage="recovery", summary="程序重启后无法确认原执行结果", error_code="EXECUTION_STATE_UNCERTAIN", needs_manual=True, next_action="先执行结果回查或人工确认，禁止自动重跑", retryable=False, source="recovery", extra={"finishedAt": now_iso()})
            else:
                task = self.store.transition(task, STATE_BLOCKED, stage="recovery", summary="程序重启后任务需要重新预检", error_code="RECOVERY_RECHECK_REQUIRED", next_action="确认环境后执行 task retry", retryable=True, source="recovery")
            recovered.append(public_task(task, include_result=False))
        return recovered


def process_is_active(pid: int, start_token: int | None = None) -> bool:
    if pid <= 0:
        return False
    handle = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid)
    if not handle:
        return False
    try:
        exit_code = ctypes.c_ulong()
        if not ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
            return False
        if exit_code.value != 259:
            return False
        if start_token is None:
            return True
        return ResourceMutex._process_start_token(pid) == int(start_token)
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)
