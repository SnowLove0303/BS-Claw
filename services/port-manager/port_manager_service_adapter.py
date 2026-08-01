from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


CREATE_NO_WINDOW = 0x08000000
ACTION_MAP = {
    "service-check": "ServiceCheck",
    "list-resources": "List",
    "resource-detail": "Detail",
    "check-resource": "Check",
    "storage-plan": "StoragePlan",
}
FORBIDDEN_ACTIONS = {
    "Register",
    "Edit",
    "Delete",
    "Enable",
    "Disable",
    "CheckAll",
    "Open",
    "CleanCache",
    "CreateLoginTestProfile",
    "ResetLoginPlan",
    "HuiceLogin",
    "AcquireLease",
    "ReleaseLease",
    "LoginCheck",
    "CancelLoginCheck",
}


def _result(
    success: bool,
    *,
    status: str,
    result: Any,
    error_code: str | None,
    message: str,
    evidence: Any,
    service_state_writes_executed: bool = False,
) -> dict[str, Any]:
    return {
        "success": success,
        "status": status,
        "result": result,
        "errorCode": error_code,
        "message": message,
        "needsManualAction": False,
        "evidence": evidence,
        "businessWritesExecuted": False,
        "serviceStateWritesExecuted": service_state_writes_executed,
    }


def _resolve_port_manager_root() -> Path:
    configured = os.environ.get("BSCLAW_PORT_MANAGER_ROOT", "").strip()
    if configured:
        candidate = Path(configured)
    else:
        candidate = Path(__file__).resolve().parents[3] / "PortManager-Phase1"
    resolved = candidate.resolve(strict=False)
    if resolved.drive.upper() != "F:":
        raise RuntimeError("PORT_MANAGER_F_DRIVE_REQUIRED")
    return resolved


def _safe_status(status: Any) -> dict[str, Any]:
    if not isinstance(status, dict):
        return {}
    allowed = (
        "connectionStatus",
        "pageStatus",
        "loginStatus",
        "loginApiProbeStatus",
        "loginConfidence",
        "checkedAt",
        "loginCheckedAt",
        "lastAuthenticatedAt",
        "watcherErrorCode",
    )
    return {key: status.get(key) for key in allowed if key in status}


def _safe_resource(resource: Any) -> dict[str, Any]:
    if not isinstance(resource, dict):
        return {}
    safe = {
        "resourceId": resource.get("resourceId"),
        "resourceName": resource.get("resourceName"),
        "platformName": resource.get("platformName"),
        "hostName": resource.get("hostName"),
        "port": resource.get("port"),
        "connectionMode": resource.get("connectionMode"),
        "enabled": resource.get("enabled"),
    }
    status = _safe_status(resource.get("lastStatus"))
    if status:
        safe["status"] = status
    return safe


def _safe_payload(action: str, data: Any) -> dict[str, Any]:
    if action == "service-check" and isinstance(data, dict):
        return {
            "serviceId": data.get("serviceId"),
            "entryAvailable": bool(data.get("entryAvailable")),
            "jsonContract": data.get("jsonContract"),
            "resourceCount": int(data.get("resourceCount") or 0),
            "sqliteIntegrity": data.get("sqliteIntegrity"),
            "schemaVersion": data.get("schemaVersion"),
            "checkedAt": data.get("checkedAt"),
            "readOnly": bool(data.get("readOnly")),
        }
    if action == "list-resources":
        resources = data if isinstance(data, list) else []
        return {
            "resourceCount": len(resources),
            "resources": [_safe_resource(item) for item in resources],
        }
    if action == "resource-detail":
        return {"resource": _safe_resource(data)}
    if action == "check-resource" and isinstance(data, dict):
        resource = data.get("resource") or data.get("Resource")
        if not isinstance(resource, dict):
            resource = data
        safe = _safe_resource(resource)
        status = (
            data.get("status")
            or data.get("Status")
            or data.get("lastStatus")
        )
        if not isinstance(status, dict) and isinstance(resource, dict):
            status = resource.get("status") or resource.get("lastStatus")
        safe_status = _safe_status(status)
        if safe_status:
            safe["lastStatus"] = safe_status
        return {"resource": safe}
    if action == "storage-plan" and isinstance(data, dict):
        totals = data.get("totals") if isinstance(data.get("totals"), dict) else {}
        profiles = data.get("profiles") if isinstance(data.get("profiles"), list) else []
        return {
            "executeMode": data.get("executeMode"),
            "readOnly": bool(data.get("readOnly")),
            "resourceId": data.get("resourceId"),
            "totals": {
                key: totals.get(key)
                for key in (
                    "observedBytes",
                    "codeBytes",
                    "databaseFactBytes",
                    "logBytes",
                    "testArtifactBytes",
                    "runtimeBytes",
                    "chromeProfileBytes",
                    "reproducibleChromeCacheBytes",
                    "nonCacheProfileBytes",
                )
            },
            "profileCount": len(profiles),
            "promotionBlocked": bool(data.get("rawFolderPromotionBlocked")),
            "promotionBlockers": list(data.get("promotionBlockers") or []),
        }
    return {}


def _invoke(action: str, resource_id: str, timeout: int) -> dict[str, Any]:
    if action not in ACTION_MAP:
        return _result(
            False,
            status="blocked",
            result=None,
            error_code="SERVICE_ACTION_NOT_ALLOWED",
            message="端口管理服务适配器未开放该动作。",
            evidence={"allowedActions": sorted(ACTION_MAP)},
        )
    public_action = ACTION_MAP[action]
    if public_action in FORBIDDEN_ACTIONS:
        return _result(
            False,
            status="blocked",
            result=None,
            error_code="SERVICE_ACTION_FORBIDDEN",
            message="该动作会改变服务状态，本阶段禁止自动调度。",
            evidence={"readOnly": False},
        )
    root = _resolve_port_manager_root()
    entry = root / "port-manager.ps1"
    if not entry.is_file():
        return _result(
            False,
            status="blocked",
            result=None,
            error_code="PORT_MANAGER_ENTRY_NOT_FOUND",
            message="未找到端口管理公共入口。",
            evidence={"entryAvailable": False},
        )
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(entry),
        "-Action",
        public_action,
        "-OutputFormat",
        "Json",
        "-NonInteractive",
    ]
    if action in {"resource-detail", "check-resource", "storage-plan"} and resource_id:
        command.extend(["-ResourceId", resource_id])
    if action in {"resource-detail", "check-resource"} and not resource_id:
        return _result(
            False,
            status="blocked",
            result=None,
            error_code="RESOURCE_ID_REQUIRED",
            message="该资源操作必须提供 ResourceId。",
            evidence={"resourceIdProvided": False},
        )
    try:
        completed = subprocess.run(
            command,
            cwd=str(root),
            capture_output=True,
            shell=False,
            timeout=max(3, timeout),
            creationflags=CREATE_NO_WINDOW,
        )
    except subprocess.TimeoutExpired:
        return _result(
            False,
            status="failed",
            result=None,
            error_code="PORT_MANAGER_TIMEOUT",
            message="端口管理公共入口执行超时。",
            evidence={"publicAction": public_action},
        )
    try:
        envelope = json.loads(completed.stdout.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return _result(
            False,
            status="failed",
            result=None,
            error_code="PORT_MANAGER_INVALID_JSON",
            message="端口管理没有返回单一有效 JSON。",
            evidence={
                "publicAction": public_action,
                "exitCode": completed.returncode,
            },
        )
    if not isinstance(envelope, dict):
        return _result(
            False,
            status="failed",
            result=None,
            error_code="PORT_MANAGER_INVALID_ENVELOPE",
            message="端口管理返回信封不是 JSON 对象。",
            evidence={"publicAction": public_action},
        )
    success = completed.returncode == 0 and envelope.get("success") is True
    return _result(
        success,
        status="succeeded" if success else "failed",
        result=_safe_payload(action, envelope.get("data")),
        error_code=None if success else str(envelope.get("errorCode") or "PORT_MANAGER_FAILED"),
        message=(
            "端口管理只读动作与结果回查成功。"
            if success
            else str(envelope.get("message") or "端口管理只读动作失败。")[:300]
        ),
        evidence={
            "publicAction": public_action,
            "exitCode": completed.returncode,
            "singleJsonDocument": True,
            "writeLevel": (
                "service-state-write" if action == "check-resource" else "pure-read"
            ),
        },
        service_state_writes_executed=action == "check-resource" and success,
    )


def main() -> int:
    try:
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8-sig"))
        action = str(payload.get("action") or "")
        resource = payload.get("resource")
        resource_id = (
            str(resource.get("resourceId") or "")
            if isinstance(resource, dict)
            else ""
        )
        timeout = int(payload.get("timeoutSeconds") or 60)
        output = _invoke(action, resource_id, timeout)
    except (ValueError, TypeError, RuntimeError, json.JSONDecodeError) as exc:
        code = str(exc) if str(exc).startswith("PORT_MANAGER_") else "SERVICE_ADAPTER_FAILED"
        output = _result(
            False,
            status="failed",
            result=None,
            error_code=code,
            message="端口管理服务适配器无法处理本次请求。",
            evidence={"requestAccepted": False},
        )
    sys.stdout.write(json.dumps(output, ensure_ascii=False))
    return 0 if output["success"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
