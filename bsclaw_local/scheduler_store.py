from __future__ import annotations

import json
import os
import uuid
from pathlib import Path
from typing import Any

from .models import now_iso
from .scheduler_models import ALLOWED_TRANSITIONS, STATE_CREATED, TERMINAL_STATES


PROTECTED_KEY_PARTS = (
    "password",
    "passwd",
    "pwd",
    "cookie",
    "token",
    "authorization",
    "authheader",
    "secret",
    "credentialvalue",
)


class SchedulerDataError(RuntimeError):
    pass


def contains_sensitive_key(value: Any) -> bool:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = "".join(ch for ch in str(key).lower() if ch.isalnum())
            if any(part in normalized for part in PROTECTED_KEY_PARTS):
                return True
            if contains_sensitive_key(child):
                return True
    elif isinstance(value, list):
        return any(contains_sensitive_key(item) for item in value)
    return False


def sanitize_text(value: Any, limit: int = 300) -> str:
    text = str(value or "").strip()
    lowered = text.lower()
    if any(part in lowered for part in PROTECTED_KEY_PARTS):
        return "受保护信息已脱敏"
    return text[:limit]


def redact_structure(value: Any, *, depth: int = 0) -> Any:
    if depth > 8:
        return "[结构过深，已截断]"
    if isinstance(value, dict):
        output: dict[str, Any] = {}
        for key, child in list(value.items())[:200]:
            normalized = "".join(ch for ch in str(key).lower() if ch.isalnum())
            if any(part in normalized for part in PROTECTED_KEY_PARTS):
                output[str(key)] = "[已脱敏]"
            else:
                output[str(key)] = redact_structure(child, depth=depth + 1)
        return output
    if isinstance(value, list):
        return [redact_structure(item, depth=depth + 1) for item in value[:200]]
    if isinstance(value, str):
        return value[:2000]
    if value is None or isinstance(value, (bool, int, float)):
        return value
    return sanitize_text(value, 500)


class SchedulerStore:
    def __init__(self, data_root: Path) -> None:
        self.root = data_root / "scheduler"
        self.tasks_root = self.root / "tasks"
        self.audit_path = self.root / "audit.jsonl"

    def create(
        self,
        *,
        module_id: str,
        action: str,
        parameters: dict[str, Any],
        resource_id: str,
        timeout_seconds: int,
    ) -> dict[str, Any]:
        if contains_sensitive_key(parameters):
            raise SchedulerDataError(
                "任务参数包含禁止持久化的敏感字段，请改用受控凭据引用。"
            )
        now = now_iso()
        task_id = f"TASK-{uuid.uuid4().hex[:12].upper()}"
        audit_id = f"AUDIT-{uuid.uuid4().hex[:12].upper()}"
        task = {
            "schemaVersion": 1,
            "taskId": task_id,
            "auditId": audit_id,
            "moduleId": module_id,
            "moduleVersion": None,
            "action": action,
            "parameters": parameters,
            "resourceId": resource_id or None,
            "state": STATE_CREATED,
            "stage": "created",
            "createdAt": now,
            "updatedAt": now,
            "startedAt": None,
            "finishedAt": None,
            "timeoutSeconds": timeout_seconds,
            "deadlineAt": None,
            "attempt": 1,
            "errorCode": None,
            "summary": "任务已创建",
            "needsManualAction": False,
            "nextAction": "等待预检",
            "businessWritesDeclared": False,
            "businessWritesExecuted": False,
            "writeLevel": "pure-read",
            "serviceStateWritesDeclared": False,
            "serviceStateWritesExecuted": False,
            "retryable": False,
            "result": None,
            "verification": None,
            "events": [],
        }
        self._write(task)
        self.append_event(
            task,
            to_state=STATE_CREATED,
            reason="任务已创建",
            error_code="",
            source="submit",
        )
        return self.load(task_id)

    def load(self, task_id: str) -> dict[str, Any]:
        path = self._task_path(task_id)
        if not path.is_file():
            raise SchedulerDataError("未找到指定任务。")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SchedulerDataError("任务记录无法读取。") from exc
        if not isinstance(payload, dict) or payload.get("taskId") != task_id:
            raise SchedulerDataError("任务记录格式无效。")
        return payload

    def list(self, limit: int = 50) -> list[dict[str, Any]]:
        if not self.tasks_root.is_dir():
            return []
        records: list[dict[str, Any]] = []
        for path in self.tasks_root.glob("TASK-*.json"):
            try:
                item = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if isinstance(item, dict):
                records.append(item)
        records.sort(key=lambda item: str(item.get("createdAt") or ""), reverse=True)
        return records[: max(1, min(limit, 200))]

    def transition(
        self,
        task: dict[str, Any],
        to_state: str,
        *,
        stage: str,
        summary: str,
        error_code: str = "",
        needs_manual: bool = False,
        next_action: str = "",
        retryable: bool | None = None,
        source: str = "scheduler",
        extra: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        current = str(task.get("state") or "")
        if current != to_state and to_state not in ALLOWED_TRANSITIONS.get(current, set()):
            raise SchedulerDataError(f"不允许从“{current}”变更为“{to_state}”。")
        task["state"] = to_state
        task["stage"] = stage
        task["summary"] = sanitize_text(summary)
        task["errorCode"] = error_code or None
        task["needsManualAction"] = needs_manual
        task["nextAction"] = sanitize_text(next_action)
        task["updatedAt"] = now_iso()
        if retryable is not None:
            task["retryable"] = retryable
        if to_state in TERMINAL_STATES:
            task["workerPid"] = None
            task["workerFinishedAt"] = now_iso()
        if extra:
            task.update(extra)
        self.append_event(
            task,
            to_state=to_state,
            reason=summary,
            error_code=error_code,
            source=source,
            persist=False,
        )
        self._write(task)
        return task

    def append_event(
        self,
        task: dict[str, Any],
        *,
        to_state: str,
        reason: str,
        error_code: str,
        source: str,
        persist: bool = True,
    ) -> None:
        events = task.setdefault("events", [])
        previous = events[-1]["toState"] if events else None
        event = {
            "eventId": f"EVT-{uuid.uuid4().hex[:10].upper()}",
            "taskId": task["taskId"],
            "fromState": previous,
            "toState": to_state,
            "reason": sanitize_text(reason),
            "errorCode": error_code or None,
            "source": source,
            "occurredAt": now_iso(),
        }
        events.append(event)
        self._append_audit(task, event)
        if persist:
            self._write(task)

    def _append_audit(self, task: dict[str, Any], event: dict[str, Any]) -> None:
        self.root.mkdir(parents=True, exist_ok=True)
        record = {
            "auditId": task["auditId"],
            "taskId": task["taskId"],
            "moduleId": task.get("moduleId"),
            "action": task.get("action"),
            "resourceId": task.get("resourceId"),
            "fromState": event.get("fromState"),
            "toState": event.get("toState"),
            "occurredAt": event.get("occurredAt"),
            "errorCode": event.get("errorCode"),
            "summary": event.get("reason"),
            "businessWritesExecuted": bool(task.get("businessWritesExecuted")),
            "writeLevel": str(task.get("writeLevel") or "pure-read"),
            "serviceStateWritesExecuted": bool(
                task.get("serviceStateWritesExecuted")
            ),
            "sensitiveValuesIncluded": False,
        }
        with self.audit_path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
            stream.write("\n")

    def _task_path(self, task_id: str) -> Path:
        if not task_id.startswith("TASK-") or any(
            ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for ch in task_id
        ):
            raise SchedulerDataError("taskId 格式无效。")
        return self.tasks_root / f"{task_id}.json"

    def _write(self, task: dict[str, Any]) -> None:
        self.tasks_root.mkdir(parents=True, exist_ok=True)
        path = self._task_path(str(task["taskId"]))
        temporary = path.with_suffix(f".{os.getpid()}.tmp")
        temporary.write_text(
            json.dumps(task, ensure_ascii=False, indent=2),
            encoding="utf-8",
            newline="\n",
        )
        temporary.replace(path)
