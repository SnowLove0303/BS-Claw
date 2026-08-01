from __future__ import annotations

import os
import subprocess
import sys
from datetime import datetime, timedelta
from typing import Any

from .capabilities import WRITE_LEVEL_PURE_READ
from .models import now_iso
from .module_registry import ModuleRegistry
from .plugin_protocol import execute_plugin
from .port_manager import PortManagerAdapter
from .scheduler_models import (
    STATE_CANCELLED,
    STATE_FAILED,
    STATE_PREFLIGHT,
    STATE_RUNNING,
    STATE_SUCCEEDED,
    STATE_TIMED_OUT,
    STATE_UNVERIFIED,
    STATE_WAITING_MANUAL,
    parse_iso,
)
from .scheduler_preflight import SchedulerPreflight
from .scheduler_store import SchedulerDataError, SchedulerStore
from .scheduler_verification import SchedulerVerifier
from .scheduler_view import plugin_input, public_task


class SchedulerExecution:
    def __init__(self, store: SchedulerStore, registry: ModuleRegistry, port_manager: PortManagerAdapter) -> None:
        self.store = store
        self.preflight = SchedulerPreflight(store, registry, port_manager)
        self.verifier = SchedulerVerifier(store)

    def start(self, task: dict[str, Any], *, already_preflight: bool = False, resume_running: bool = False) -> dict[str, Any]:
        if resume_running:
            if task.get("state") != STATE_RUNNING:
                return public_task(task, include_result=True)
        elif not already_preflight:
            task = self.store.transition(
                task, STATE_PREFLIGHT, stage="preflight",
                summary="正在检查模块、动作、资源和登录门禁",
                next_action="等待预检结果",
            )
        checked = self.preflight.evaluate(task)
        if checked.terminal is not None:
            return checked.terminal
        task, module, action = checked.task, checked.module, checked.action
        assert module is not None and action is not None
        timeout_seconds = checked.timeout_seconds
        if not resume_running:
            started = datetime.now().astimezone()
            is_storage_plan = str(task.get("action") or "") == "storage-plan"
            task = self.store.transition(
                task, STATE_RUNNING, stage="plugin-execution",
                summary=("正在扫描 Profile 体积，数据较大时可能需要几十秒" if is_storage_plan else "模块已通过预检，任务已提交执行"),
                next_action=("可使用 task status 查询进度；本动作只生成计划，不删除数据" if is_storage_plan else "可立即使用 task status 查询"),
                extra={"startedAt": started.isoformat(), "deadlineAt": (started + timedelta(seconds=timeout_seconds)).isoformat()},
            )
            return self._dispatch_worker(task)

        deadline = parse_iso(task.get("deadlineAt"))
        if deadline is not None:
            remaining = int((deadline - datetime.now().astimezone()).total_seconds())
            if remaining <= 0:
                task = self.store.transition(
                    task, STATE_TIMED_OUT, stage="plugin-execution",
                    summary="任务在执行进程启动前已超过截止时间",
                    error_code="TASK_DEADLINE_EXCEEDED",
                    next_action="确认没有业务写入后再决定是否重试",
                    retryable=True, extra={"finishedAt": now_iso()},
                )
                return public_task(task, include_result=True)
            timeout_seconds = min(timeout_seconds, remaining)
        execution = execute_plugin(
            module, plugin_input(task, module, action, "execute"),
            timeout_seconds=timeout_seconds,
            cancel_requested=lambda: self.is_cancelled(str(task["taskId"])),
        )
        if execution.cancelled:
            return public_task(self.store.load(str(task["taskId"])), include_result=True)
        if execution.timed_out:
            task = self.store.transition(task, STATE_TIMED_OUT, stage="plugin-execution", summary=execution.message, error_code=execution.error_code, next_action="确认没有业务写入后再决定是否重试", retryable=True, extra={"finishedAt": now_iso()})
            return public_task(task, include_result=True)
        if execution.payload is None:
            task = self.store.transition(task, STATE_FAILED, stage="plugin-execution", summary=execution.message, error_code=execution.error_code, next_action="修复插件输出契约后执行 task retry", retryable=True, extra={"finishedAt": now_iso()})
            return public_task(task, include_result=True)
        task["result"] = execution.payload.get("result")
        task["businessWritesExecuted"] = bool(execution.payload.get("businessWritesExecuted"))
        task["serviceStateWritesExecuted"] = bool(execution.payload.get("serviceStateWritesExecuted"))
        terminal = self._validate_execution(task, execution, str(task.get("writeLevel") or WRITE_LEVEL_PURE_READ))
        if terminal is not None:
            return terminal
        result_check = action.get("resultCheck")
        if isinstance(result_check, dict) and result_check.get("mode") == "plugin":
            return self.verifier.verify_plugin(task, module, action, result_check, timeout_seconds, lambda: self.is_cancelled(str(task["taskId"])))
        if isinstance(result_check, dict) and result_check.get("mode") == "result-contract":
            return self.verifier.verify_contract(task, result_check)
        task = self.store.transition(task, STATE_SUCCEEDED, stage="completed", summary=execution.message or "只读任务执行成功", next_action="可查看 task result", retryable=False, extra={"finishedAt": now_iso()})
        return public_task(task, include_result=True)

    def run_worker(self, task_id: str) -> dict[str, Any]:
        task = self.store.load(task_id)
        if int(task.get("workerPid") or 0) != os.getpid():
            raise SchedulerDataError("执行进程身份与任务记录不一致。")
        return self.start(task, resume_running=True)

    def is_cancelled(self, task_id: str) -> bool:
        try:
            return self.store.load(task_id).get("state") == STATE_CANCELLED
        except SchedulerDataError:
            return False

    def _dispatch_worker(self, task: dict[str, Any]) -> dict[str, Any]:
        local_root = self.store.root.parent.parent
        command = [sys.executable, "-B", str(local_root / "scheduler-worker.py"), "--task-id", str(task["taskId"])]
        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        worker_log_root = self.store.root / "worker-logs"
        worker_log_root.mkdir(parents=True, exist_ok=True)
        try:
            with (worker_log_root / f"{task['taskId']}.stdout.log").open("wb") as stdout_file, (worker_log_root / f"{task['taskId']}.stderr.log").open("wb") as stderr_file:
                worker = subprocess.Popen(command, cwd=str(local_root), stdin=subprocess.DEVNULL, stdout=stdout_file, stderr=stderr_file, shell=False, creationflags=0x08000000, env=environment)
        except OSError:
            task = self.store.transition(task, STATE_FAILED, stage="dispatcher", summary="无法启动任务执行进程", error_code="TASK_WORKER_START_FAILED", next_action="检查 F 盘 Python 后执行 task retry", retryable=True, extra={"finishedAt": now_iso()})
            return public_task(task, include_result=True)
        task = self.store.transition(
            task, STATE_RUNNING, stage="plugin-execution",
            summary=("正在扫描 Profile 体积，数据较大时可能需要几十秒" if str(task.get("action") or "") == "storage-plan" else "任务已进入执行进程"),
            next_action=("可使用 task status 查询进度；本动作只生成计划，不删除数据" if str(task.get("action") or "") == "storage-plan" else "可立即使用 task status 查询"),
            source="dispatcher", extra={"workerPid": worker.pid, "workerStartedAt": now_iso()},
        )
        return public_task(task, include_result=False)

    def _validate_execution(self, task: dict[str, Any], execution: Any, write_level: str) -> dict[str, Any] | None:
        if task["businessWritesExecuted"]:
            return self._terminal(task, STATE_UNVERIFIED, "只读任务报告了业务写入，结果不能放行", "UNEXPECTED_BUSINESS_WRITE", "立即人工核对业务结果和插件实现", False, True)
        if write_level == WRITE_LEVEL_PURE_READ and task["serviceStateWritesExecuted"]:
            return self._terminal(task, STATE_UNVERIFIED, "纯展示动作报告了服务状态写入，结果不能放行", "UNEXPECTED_SERVICE_STATE_WRITE", "核对插件动作的写入等级声明", False, True)
        if bool(execution.payload.get("needsManualAction")):
            return self._terminal(task, STATE_WAITING_MANUAL, execution.message or "插件要求人工处理", execution.error_code, "按插件提示完成人工处理后重新预检", False, True, finished=False)
        if not execution.success:
            return self._terminal(task, STATE_FAILED, execution.message or "插件执行失败", execution.error_code or "PLUGIN_EXECUTION_FAILED", "根据错误码修复后执行 task retry", True, False)
        return None

    def _terminal(self, task: dict[str, Any], state: str, summary: str, error_code: str, next_action: str, retryable: bool, needs_manual: bool, *, finished: bool = True) -> dict[str, Any]:
        task = self.store.transition(task, state, stage="plugin-execution", summary=summary, error_code=error_code, needs_manual=needs_manual, next_action=next_action, retryable=retryable, extra={"finishedAt": now_iso()} if finished else None)
        return public_task(task, include_result=True)
