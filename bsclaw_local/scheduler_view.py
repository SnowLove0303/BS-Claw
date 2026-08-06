from __future__ import annotations

from typing import Any

from .capabilities import (
    WRITE_LEVEL_BUSINESS,
    WRITE_LEVEL_PURE_READ,
    WRITE_LEVEL_SERVICE_STATE,
    action_write_level,
)
from .module_registry import RegisteredModule
from .huice_execution_context import HuiceExecutionContext


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
        # Progress is part of the ordinary status contract.  It is deliberately
        # exposed even when the caller does not request the full result so a
        # user-facing task center can show live segmented work without needing
        # a second debug-only result call.
        "progress": task.get("progress"),
        "currentResourceId": (
            task.get("progress", {}).get("currentResourceId")
            if isinstance(task.get("progress"), dict)
            else None
        ),
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
    else:
        # Keep the final result summary available to status polling.  The full
        # result endpoint remains available for callers that need every field.
        output["result"] = task.get("result")
    return output


def plugin_input(
    task: dict[str, Any],
    module: RegisteredModule,
    action: dict[str, Any],
    run_mode: str,
) -> dict[str, Any]:
    write_level = action_write_level(action)
    resource = task.get("resourceEvidence") if isinstance(task.get("resourceEvidence"), dict) else None
    context = HuiceExecutionContext.from_resource(resource)
    return {
        "protocolVersion": 1,
        "taskId": task["taskId"],
        "moduleId": task["moduleId"],
        "moduleVersion": module.manifest.get("version"),
        "action": task["action"],
        "parameters": task["parameters"],
        "runMode": run_mode,
        "resource": (
            context.public_dict() if context is not None else {
                "resourceId": task.get("resourceId")
            } if task.get("resourceId") else None
        ),
        "executionContext": context.public_dict() if context is not None else None,
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
