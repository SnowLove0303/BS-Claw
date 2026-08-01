from __future__ import annotations

from typing import Any

from .capabilities import (
    WRITE_LEVEL_BUSINESS,
    WRITE_LEVEL_PURE_READ,
    WRITE_LEVEL_SERVICE_STATE,
    action_write_level,
)
from .module_registry import RegisteredModule


def public_task(task: dict[str, Any], *, include_result: bool) -> dict[str, Any]:
    output = {
        "taskId": task.get("taskId"),
        "moduleId": task.get("moduleId"),
        "moduleVersion": task.get("moduleVersion"),
        "action": task.get("action"),
        "resourceId": task.get("resourceId"),
        "state": task.get("state"),
        "stage": task.get("stage"),
        "createdAt": task.get("createdAt"),
        "updatedAt": task.get("updatedAt"),
        "startedAt": task.get("startedAt"),
        "finishedAt": task.get("finishedAt"),
        "attempt": task.get("attempt"),
        "errorCode": task.get("errorCode"),
        "summary": task.get("summary"),
        "needsManualAction": bool(task.get("needsManualAction")),
        "nextAction": task.get("nextAction"),
        "businessWritesDeclared": bool(task.get("businessWritesDeclared")),
        "businessWritesExecuted": bool(task.get("businessWritesExecuted")),
        "writeLevel": str(task.get("writeLevel") or WRITE_LEVEL_PURE_READ),
        "serviceStateWritesDeclared": bool(task.get("serviceStateWritesDeclared")),
        "serviceStateWritesExecuted": bool(task.get("serviceStateWritesExecuted")),
        "retryable": bool(task.get("retryable")),
        "auditId": task.get("auditId"),
    }
    if include_result:
        output["result"] = task.get("result")
        output["verification"] = task.get("verification")
    return output


def plugin_input(
    task: dict[str, Any],
    module: RegisteredModule,
    action: dict[str, Any],
    run_mode: str,
) -> dict[str, Any]:
    write_level = action_write_level(action)
    return {
        "protocolVersion": 1,
        "taskId": task["taskId"],
        "moduleId": task["moduleId"],
        "moduleVersion": module.manifest.get("version"),
        "action": task["action"],
        "parameters": task["parameters"],
        "runMode": run_mode,
        "resource": (
            {"resourceId": task.get("resourceId")}
            if task.get("resourceId")
            else None
        ),
        "writeLevel": write_level,
        "readOnly": write_level == WRITE_LEVEL_PURE_READ,
        "serviceStateWrite": write_level == WRITE_LEVEL_SERVICE_STATE,
        "businessWrite": write_level == WRITE_LEVEL_BUSINESS,
        "timeoutSeconds": task["timeoutSeconds"],
        "audit": {
            "auditId": task["auditId"],
            "submittedAt": task["createdAt"],
        },
    }
