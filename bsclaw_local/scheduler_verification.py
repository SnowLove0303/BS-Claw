from __future__ import annotations

from typing import Any, Callable

from .models import now_iso
from .module_registry import RegisteredModule
from .plugin_protocol import execute_plugin
from .scheduler_models import (
    STATE_FAILED,
    STATE_SUCCEEDED,
    STATE_UNVERIFIED,
    STATE_WAITING_MANUAL,
    STATE_WAITING_VERIFY,
)
from .scheduler_store import SchedulerStore
from .scheduler_view import plugin_input, public_task


class SchedulerVerifier:
    def __init__(self, store: SchedulerStore) -> None:
        self.store = store

    def verify_plugin(
        self,
        task: dict[str, Any],
        module: RegisteredModule,
        action: dict[str, Any],
        result_check: dict[str, Any],
        timeout_seconds: int,
        is_cancelled: Callable[[], bool],
    ) -> dict[str, Any]:
        task = self.store.transition(
            task, STATE_WAITING_VERIFY, stage="result-verification",
            summary="正在执行结果回查", next_action="等待回查结果",
        )
        verify_action = str(result_check.get("action") or "")
        if not verify_action:
            task = self.store.transition(
                task, STATE_UNVERIFIED, stage="result-verification",
                summary="模块声明需要回查，但未声明回查动作",
                error_code="RESULT_CHECK_INCOMPLETE", needs_manual=True,
                next_action="补齐回查契约或人工确认结果", retryable=False,
                extra={"finishedAt": now_iso()},
            )
            return public_task(task, include_result=True)
        verify_input = plugin_input(task, module, action, "verify")
        verify_input["verificationAction"] = verify_action
        verification = execute_plugin(
            module, verify_input, timeout_seconds=timeout_seconds,
            cancel_requested=is_cancelled,
        )
        if verification.cancelled:
            return public_task(self.store.load(str(task["taskId"])), include_result=True)
        task["verification"] = verification.payload
        if verification.payload is None or not verification.success:
            state = STATE_WAITING_MANUAL if verification.payload and verification.payload.get("needsManualAction") else STATE_FAILED
            task = self.store.transition(
                task, state, stage="result-verification",
                summary=verification.message or "结果回查失败",
                error_code=verification.error_code or "RESULT_CHECK_FAILED",
                needs_manual=state == STATE_WAITING_MANUAL,
                next_action="修复登录、权限或回查接口后重新回查",
                retryable=False,
                extra={"finishedAt": now_iso() if state == STATE_FAILED else None},
            )
            return public_task(task, include_result=True)
        task = self.store.transition(
            task, STATE_SUCCEEDED, stage="completed",
            summary="任务执行与结果回查均成功", next_action="可查看 task result",
            retryable=False, extra={"finishedAt": now_iso()},
        )
        return public_task(task, include_result=True)

    def verify_contract(
        self, task: dict[str, Any], result_check: dict[str, Any]
    ) -> dict[str, Any]:
        is_storage_plan = str(task.get("action") or "") == "storage-plan"
        task = self.store.transition(
            task, STATE_WAITING_VERIFY, stage="result-verification",
            summary=("正在校验已生成的存储计划，不重复扫描 Profile" if is_storage_plan else "正在校验本次服务结果，不重复执行操作"),
            next_action="等待本地契约校验完成",
        )
        result = task.get("result")
        required_fields = result_check.get("requiredFields")
        expected = result_check.get("expected")
        missing = [str(field) for field in (required_fields if isinstance(required_fields, list) else []) if not isinstance(result, dict) or field not in result]
        mismatched = [str(field) for field, value in (expected.items() if isinstance(expected, dict) else []) if not isinstance(result, dict) or result.get(field) != value]
        task["verification"] = {
            "mode": "result-contract", "resultReused": True,
            "verified": not missing and not mismatched,
            "missingFields": missing, "mismatchedFields": mismatched,
            "checkedAt": now_iso(),
        }
        if missing or mismatched:
            task = self.store.transition(
                task, STATE_FAILED, stage="result-verification",
                summary="服务结果不符合声明的输出契约",
                error_code="RESULT_CONTRACT_MISMATCH",
                next_action="检查 PortManager 公开 JSON 契约后重试",
                retryable=True, extra={"finishedAt": now_iso()},
            )
            return public_task(task, include_result=True)
        task = self.store.transition(
            task, STATE_SUCCEEDED, stage="completed",
            summary=("存储计划已生成并完成纯展示结果校验" if is_storage_plan else "服务状态检查已完成并写入最新运行状态"),
            next_action=("可查看任务结果；本次没有删除数据" if is_storage_plan else "可返回资源详情继续使用"),
            retryable=False, extra={"finishedAt": now_iso()},
        )
        return public_task(task, include_result=True)
