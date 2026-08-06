from __future__ import annotations

import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from .capabilities import WRITE_LEVEL_PURE_READ
from .models import now_iso
from .module_registry import ModuleRegistry
from .plugin_protocol import execute_plugin
from .port_manager import PortManagerAdapter
from .scheduler_models import (
    STATE_CANCELLED,
    STATE_BLOCKED,
    STATE_FAILED,
    STATE_PARTIAL_SUCCESS,
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
from .resource_mutex import ResourceMutex
from .resource_snapshot import project_resource


class SchedulerExecution:
    def __init__(self, store: SchedulerStore, registry: ModuleRegistry, port_manager: PortManagerAdapter) -> None:
        self.store = store
        self.port_manager = port_manager
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
        if str(task.get("action") or "") == "check-all":
            return self._execute_segmented_check_all(task, timeout_seconds)
        mutex = None
        lease_id = ""
        lease_record: dict[str, Any] | None = None
        if task.get("resourceId"):
            mutex = ResourceMutex(self.store.root, str(task["resourceId"]), str(task["taskId"]))
            if not mutex.acquire():
                return self._terminal(task, STATE_BLOCKED, "该资源正在被其他任务使用", "RESOURCE_BUSY", "等待当前任务完成后重新检查", True, False)
            lease_result = self.port_manager.acquire_lease(
                str(task["resourceId"]),
                task_ref=str(task["taskId"]),
                duration_seconds=min(max(timeout_seconds + 120, 300), 3600),
            )
            lease_id = self._extract_lease_id(lease_result)
            lease_record = {
                "acquire": {
                    "success": lease_result.success,
                    "message": lease_result.message,
                    "errorCode": lease_result.error_code,
                    "leaseId": lease_id or None,
                    "checkedAt": now_iso(),
                },
                "release": None,
            }
            task["resourceLease"] = lease_record
            if not lease_result.success or not lease_id:
                if mutex:
                    mutex.release()
                return self._terminal(
                    task,
                    STATE_BLOCKED,
                    lease_result.message or "无法申请 PortManager 资源租约",
                    lease_result.error_code or "LEASE_ACQUIRE_FAILED",
                    "等待资源空闲或修复 PortManager 租约服务后重试",
                    True,
                    False,
                )
        try:
            execution = execute_plugin(
                module, plugin_input(task, module, action, "execute"),
                timeout_seconds=timeout_seconds,
                cancel_requested=lambda: self.is_cancelled(str(task["taskId"])),
            )
        finally:
            if lease_id:
                release_result = self.port_manager.release_lease(lease_id)
                if lease_record is not None:
                    lease_record["release"] = {
                        "success": release_result.success,
                        "message": release_result.message,
                        "errorCode": release_result.error_code,
                        "leaseId": lease_id,
                        "checkedAt": now_iso(),
                    }
                    task["resourceLease"] = lease_record
            if mutex:
                mutex.release()
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
        if lease_record is not None:
            if isinstance(task.get("result"), dict):
                task["result"]["resourceLease"] = lease_record
            else:
                task["result"] = {"value": task.get("result"), "resourceLease": lease_record}
            release_info = lease_record.get("release") if isinstance(lease_record, dict) else None
            if not isinstance(release_info, dict) or not release_info.get("success"):
                return self._terminal(
                    task,
                    STATE_BLOCKED,
                    "业务动作已执行，但 PortManager 资源租约释放失败，结果需要先收口。",
                    "LEASE_RELEASE_FAILED",
                    "先通过 PortManager 占用查看/释放租约收口，再做只读业务回查；禁止盲目重复写入。",
                    False,
                    True,
                )
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

    def _execute_segmented_check_all(self, task: dict[str, Any], timeout_seconds: int) -> dict[str, Any]:
        """Run CheckAll as cancellable per-resource adapter calls, not one 105s PM action."""
        if self.is_cancelled(str(task["taskId"])):
            return public_task(self.store.load(str(task["taskId"])), include_result=True)
        listed = self.preflight.port_manager.list_resources(force_refresh=True)
        if not listed.success or not isinstance(listed.data, list):
            return self._terminal(task, STATE_FAILED, listed.message or "无法读取待检查资源", listed.error_code or "RESOURCE_LIST_FAILED", "先检查端口管理服务后重试", True, False)
        resources = [item for item in listed.data if isinstance(item, dict) and item.get("resourceId") and item.get("enabled", True)]
        total = len(resources)
        completed = 0
        failed: list[str] = []
        results: list[dict[str, Any]] = []
        task["result"] = {"total": total, "completed": 0, "failed": 0, "currentResourceId": None, "resources": []}
        task = self.store.transition(
            task, STATE_RUNNING, stage="resource-check-list",
            summary=f"已读取待检查资源，共 {total} 个；正在并行检查",
            next_action="可在任务中心查看完成数、失败数和当前资源；可取消",
            extra={"progress": {"total": total, "completed": 0, "failed": 0, "currentResourceId": None}},
        )
        if total == 0:
            task["result"] = {"total": 0, "completed": 0, "failed": 0, "resources": []}
            task["serviceStateWritesExecuted"] = False
            task = self.store.transition(task, STATE_SUCCEEDED, stage="completed", summary="没有启用的资源需要检查", next_action="可返回资源列表", retryable=False, extra={"finishedAt": now_iso()})
            return public_task(task, include_result=True)

        def check_one(item: dict[str, Any]) -> tuple[str, dict[str, Any]]:
            rid = str(item["resourceId"])
            mutex = ResourceMutex(self.store.root, rid, str(task["taskId"]))
            if not mutex.acquire():
                return rid, {"resourceId": rid, "success": False, "message": "该资源正在被其他任务使用", "errorCode": "RESOURCE_BUSY", "checkedAt": now_iso()}
            try:
                checked = self.preflight.port_manager.check_resource(rid)
                raw = checked.data if isinstance(checked.data, dict) else {}
                resource = self.preflight.port_manager.sanitize_checked(raw)
                connection = str(resource.get("connectionStatus") or "").lower()
                login = str(resource.get("loginStatus") or "").lower()
                api = str(resource.get("apiStatus") or resource.get("loginApiProbeStatus") or "").lower()
                outcome = "unknown"
                if any(token in connection for token in ("unavailable", "failed", "不可", "失败")):
                    outcome = "unavailable"
                elif any(token in login for token in ("login-required", "需登录", "未登录", "expired", "过期")):
                    outcome = "login-required"
                elif "logged-in" in login or "已登录" in login:
                    outcome = "ready" if (not api or "ready" in api or "可用" in api) else "repair-required"
                elif not checked.success:
                    outcome = "repair-required"
                return rid, {
                    "resourceId": rid,
                    "success": checked.success,
                    "message": checked.message,
                    "errorCode": checked.error_code or None,
                    "elapsedMs": checked.elapsed_ms,
                    "checkedAt": now_iso(),
                    "outcome": outcome,
                    "resourceName": resource.get("resourceName") or resource.get("name"),
                    "port": resource.get("port"),
                    "enabled": resource.get("enabled", True),
                    "connectionStatus": resource.get("connectionStatus"),
                    "browserStatus": resource.get("browserStatus"),
                    "pageStatus": resource.get("pageStatus"),
                    "loginStatus": resource.get("loginStatus"),
                    "loginApiProbeStatus": resource.get("apiStatus") or resource.get("loginApiProbeStatus"),
                    "apiStatus": resource.get("apiStatus"),
                    "confidence": resource.get("confidence"),
                    "snapshotAt": resource.get("snapshotAt"),
                    "freshness": resource.get("freshness"),
                    "statusSource": resource.get("statusSource"),
                    "nextAction": resource.get("nextAction"),
                    "occupancy": resource.get("occupancy"),
                    "lease": resource.get("lease"),
                }
            finally:
                mutex.release()

        with ThreadPoolExecutor(max_workers=max(1, min(4, total))) as pool:
            futures = {pool.submit(check_one, item): str(item["resourceId"]) for item in resources}
            for future in as_completed(futures):
                rid = futures[future]
                if self.is_cancelled(str(task["taskId"])):
                    for pending in futures:
                        pending.cancel()
                    return public_task(self.store.load(str(task["taskId"])), include_result=True)
                try:
                    _, item_result = future.result()
                except Exception as exc:
                    item_result = {"resourceId": rid, "success": False, "message": "该资源检查异常，其他资源继续", "errorCode": type(exc).__name__, "checkedAt": now_iso()}
                item_result = self._normalize_check_all_result(item_result, resources)
                results.append(item_result)
                completed += 1
                if not item_result.get("success"):
                    failed.append(rid)
                task["result"] = {"total": total, "completed": completed, "failed": len(failed), "currentResourceId": rid, "resources": results}
                task = self.store.transition(
                    task, STATE_RUNNING, stage="resource-check",
                    summary=f"已完成 {completed}/{total} 个资源，失败 {len(failed)} 个；当前：{rid}",
                    next_action="继续等待或取消；完成后可查看逐资源结果",
                    extra={"progress": {"total": total, "completed": completed, "failed": len(failed), "currentResourceId": rid}, "result": task["result"]},
                )
        latest = self.store.load(str(task["taskId"]))
        if latest.get("state") == "已取消":
            return public_task(latest, include_result=True)
        outcome_counts = {"ready": 0, "login-required": 0, "repair-required": 0, "unavailable": 0, "unknown": 0}
        for item in results:
            key = str(item.get("outcome") or "unknown")
            outcome_counts[key if key in outcome_counts else "unknown"] += 1
        task["result"] = {"total": total, "completed": completed, "failed": len(failed), "currentResourceId": None, "failedResources": failed, "resources": results, "outcomes": outcome_counts}
        task["serviceStateWritesExecuted"] = completed > 0
        final_state = (
            STATE_SUCCEEDED
            if not failed
            else STATE_PARTIAL_SUCCESS
            if completed > len(failed)
            else STATE_FAILED
        )
        task = self.store.transition(
            task, final_state, stage="completed", summary=(
                f"全部检查任务已完成；资源结果：可用 {outcome_counts['ready']}，需登录 {outcome_counts['login-required']}，需修复 {outcome_counts['repair-required']}，连接不可用 {outcome_counts['unavailable']}，未验证 {outcome_counts['unknown']}。"
            ),
            error_code="CHECK_ALL_PARTIAL_FAILURE" if failed else "", next_action="查看逐资源结果；失败资源可单独重新检查" if failed else "可返回资源列表",
            retryable=bool(failed), extra={"finishedAt": now_iso(), "result": task["result"]},
        )
        return public_task(task, include_result=True)

    @staticmethod
    def _normalize_check_all_result(item_result: dict[str, Any], resources: list[dict[str, Any]]) -> dict[str, Any]:
        """Keep CheckAll entries on the same public ResourceSnapshot contract."""
        base = next(
            (item for item in resources if str(item.get("resourceId") or "") == str(item_result.get("resourceId") or "")),
            {},
        )
        merged = {**base, **item_result}
        snapshot = project_resource(merged, snapshot_at=str(item_result.get("checkedAt") or now_iso()))
        output = {**item_result, **snapshot, "resource": snapshot}
        output["success"] = bool(item_result.get("success"))
        output["outcome"] = item_result.get("outcome") or "unknown"
        return output

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
        # The task store may live under an isolated data root during audits;
        # resolve the executable code root independently of runtime data.
        local_root = Path(os.environ.get("BSCLAW_LOCAL_ROOT") or str(self.store.root.parent.parent))
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
            source="dispatcher", extra={
                "workerPid": worker.pid,
                "workerStartedAt": now_iso(),
                "workerProcessStartToken": ResourceMutex._process_start_token(worker.pid),
            },
        )
        return public_task(task, include_result=False)

    def _validate_execution(self, task: dict[str, Any], execution: Any, write_level: str) -> dict[str, Any] | None:
        if task["businessWritesExecuted"] and not self._authorized_business_write(task, write_level):
            return self._terminal(task, STATE_UNVERIFIED, "只读任务报告了业务写入，结果不能放行", "UNEXPECTED_BUSINESS_WRITE", "立即人工核对业务结果和插件实现", False, True)
        if write_level == WRITE_LEVEL_PURE_READ and task["serviceStateWritesExecuted"]:
            return self._terminal(task, STATE_UNVERIFIED, "纯展示动作报告了服务状态写入，结果不能放行", "UNEXPECTED_SERVICE_STATE_WRITE", "核对插件动作的写入等级声明", False, True)
        if bool(execution.payload.get("needsManualAction")):
            return self._terminal(task, STATE_WAITING_MANUAL, execution.message or "插件要求人工处理", execution.error_code, "按插件提示完成人工处理后重新预检", False, True, finished=False)
        if not execution.success:
            return self._terminal(task, STATE_FAILED, execution.message or "插件执行失败", execution.error_code or "PLUGIN_EXECUTION_FAILED", "根据错误码修复后执行 task retry", True, False)
        return None

    @staticmethod
    def _authorized_business_write(task: dict[str, Any], write_level: str) -> bool:
        if write_level != "business-write":
            return False
        params = task.get("parameters")
        if not isinstance(params, dict):
            return False
        authorization = params.get("writeAuthorization")
        if not isinstance(authorization, dict):
            return False
        if str(task.get("action") or "") == "hot.add-distribution":
            return (
                str(authorization.get("scope") or "") == "isolated-resource"
                and str(authorization.get("status") or "") == "approved"
            )
        return (
            str(authorization.get("scope") or "") == "isolated-resource"
            and str(authorization.get("status") or "") == "approved"
            and isinstance(params.get("readbackRequest"), dict)
        )

    @staticmethod
    def _extract_lease_id(result: Any) -> str:
        data = getattr(result, "data", None)
        if not isinstance(data, dict):
            return ""
        for key in ("leaseId", "LeaseId"):
            value = data.get(key)
            if value:
                return str(value)
        for key in ("lease", "Lease", "activeLease", "ActiveLease", "occupancy", "Occupancy"):
            nested = data.get(key)
            if isinstance(nested, dict):
                for nested_key in ("leaseId", "LeaseId", "id", "Id"):
                    value = nested.get(nested_key)
                    if value:
                        return str(value)
        return ""

    def _terminal(self, task: dict[str, Any], state: str, summary: str, error_code: str, next_action: str, retryable: bool, needs_manual: bool, *, finished: bool = True) -> dict[str, Any]:
        task = self.store.transition(task, state, stage="plugin-execution", summary=summary, error_code=error_code, needs_manual=needs_manual, next_action=next_action, retryable=retryable, extra={"finishedAt": now_iso()} if finished else None)
        return public_task(task, include_result=True)
