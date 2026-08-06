from __future__ import annotations

import json
import os
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CREATE_NO_WINDOW = 0x08000000
ACTION_MAP = {
    "service-check": "ServiceCheck",
    "list-resources": "List",
    "resource-detail": "Detail",
    "check-resource": "Check",
    "storage-plan": "StoragePlan",
    "register": "Register",
    "edit": "Edit",
    "enable": "Enable",
    "disable": "Disable",
    "delete": "Delete",
    "check-all": "CheckAll",
    "occupancy": "Occupancy",
    "login-check": "LoginCheck",
    "cancel-login-check": "CancelLoginCheck",
    "open-resource": "Open",
    "login-resource": "HuiceLogin",
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
    needs_manual_action: bool = False,
) -> dict[str, Any]:
    return {
        "success": success,
        "status": status,
        "result": result,
        "errorCode": error_code,
        "message": message,
        "needsManualAction": needs_manual_action,
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
        "pageMatchStatus",
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
    checked_at = status.get("loginCheckedAt") or status.get("checkedAt")
    connection = status.get("connectionStatus") or "状态未检查"
    page = status.get("pageStatus") or status.get("pageMatchStatus") or "页面状态未检查"
    login = status.get("loginStatus") or "登录状态未检查"
    api = status.get("loginApiProbeStatus") or "接口状态未检查"
    if status:
        safe["status"] = status
    safe.update(
        {
            "connectionStatus": connection,
            "browserStatus": status.get("browserStatus") or connection,
            "pageStatus": page,
            "loginStatus": login,
            "apiStatus": api,
            "confidence": status.get("loginConfidence") or "unknown",
            "checkedAt": checked_at,
            "snapshotAt": datetime.now(timezone.utc).isoformat(),
            "freshness": "fresh" if checked_at else "never-checked",
            "statusSource": "PortManager public JSON",
            "nextAction": "reuse-resource" if login in {"logged-in", "authenticated", "已登录"} and api in {"logged-in-api-ready", "200", "ok", "已就绪"} else "check-resource",
            "nextActionLabel": "复用已登录资源" if login in {"logged-in", "authenticated", "已登录"} and api in {"logged-in-api-ready", "200", "ok", "已就绪"} else "重新检查状态",
            "occupancy": {
                "active": bool(resource.get("currentOccupancy")),
                "count": resource.get("currentOccupancy") or 0,
            },
            "lease": {"active": bool(resource.get("leaseId"))},
        }
    )
    return safe


def _safe_checked_resource(data: Any) -> dict[str, Any]:
    """Normalize PortManager Check/Detail data into one UI-safe fact shape."""
    source = (data.get("resource") or data.get("Resource")) if isinstance(data, dict) else None
    if not isinstance(source, dict):
        source = data if isinstance(data, dict) else {}
    status = (data.get("status") or data.get("Status")) if isinstance(data, dict) else None
    if not isinstance(status, dict):
        status = (data.get("lastStatus") or data.get("LastStatus")) if isinstance(data, dict) else None
    if not isinstance(status, dict):
        status = source.get("lastStatus") or source.get("LastStatus") or source.get("status") or source.get("Status")
    if not isinstance(status, dict):
        status = {}

    connection = status.get("connectionStatus") or "状态未知"
    page = status.get("pageStatus") or status.get("pageMatchStatus") or "页面状态未知"
    login = status.get("loginStatus") or "登录状态未知"
    api = status.get("loginApiProbeStatus") or "未配置可靠探针"
    confidence = status.get("loginConfidence") or "unknown"
    checked_at = status.get("loginCheckedAt") or status.get("checkedAt") or ""
    if str(login).lower() in {"logged-in", "已登录"} and str(api).lower() in {
        "logged-in-api-ready",
        "200",
        "ok",
        "已就绪",
    }:
        state = "可用"
        next_action = "可继续使用当前资源"
    elif str(login).lower() in {"未登录", "login-required", "需登录"}:
        state = "需登录"
        next_action = "进入正式登录流程"
    else:
        state = "未验证"
        next_action = "重新检查资源状态"
    safe = _safe_resource(source)
    safe.update(
        {
            "state": state,
            "connectionStatus": connection,
            "pageStatus": page,
            "loginStatus": login,
            "apiStatus": api,
            "confidence": confidence,
            "checkedAt": checked_at,
            "snapshotAt": datetime.now(timezone.utc).isoformat(),
            "freshness": "fresh" if checked_at else "never-checked",
            "statusSource": "PortManager public JSON check",
            "browserStatus": status.get("browserStatus") or connection,
            "occupancy": {
                "active": bool(source.get("currentOccupancy")),
                "count": source.get("currentOccupancy") or 0,
            },
            "lease": {"active": bool(source.get("leaseId"))},
            "summary": status.get("summary") or f"{state}：{login} / {api}",
            "nextAction": next_action,
            "nextActionLabel": "继续使用当前资源" if state == "可用" else "进入正式登录流程" if state == "需登录" else "重新检查资源状态",
            "lastStatus": _safe_status(status),
        }
    )
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
            "snapshotAt": datetime.now(timezone.utc).isoformat(),
            "statusSource": "PortManager public JSON",
            "resources": [_safe_resource(item) for item in resources],
        }
    if action in {"resource-detail", "check-resource"}:
        safe = _safe_checked_resource(data)
        result = {"resource": safe}
        if action == "check-resource":
            result.update(
                {
                    "connectionStatus": safe["connectionStatus"],
                    "pageStatus": safe["pageStatus"],
                    "loginStatus": safe["loginStatus"],
                    "apiStatus": safe["apiStatus"],
                    "confidence": safe["confidence"],
                    "checkedAt": safe["checkedAt"],
                    "snapshotAt": safe["snapshotAt"],
                    "freshness": safe["freshness"],
                    "statusSource": safe["statusSource"],
                    "browserStatus": safe["browserStatus"],
                    "occupancy": safe["occupancy"],
                    "lease": safe["lease"],
                    "nextAction": safe["nextAction"],
                }
            )
        return result
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
    if isinstance(data, list):
        return {"items": [_safe_resource(item) for item in data if isinstance(item, dict)], "count": len(data)}
    if isinstance(data, dict):
        safe = {}
        for key in ("resourceId", "resourceName", "port", "enabled", "currentOccupancy", "checkedAt", "loginDetectionTask", "cancelled", "released", "resourceCount", "sqliteIntegrity", "schemaVersion"):
            if key in data:
                safe[key] = data.get(key)
        if isinstance(data.get("resource"), dict):
            safe["resource"] = _safe_resource(data["resource"])
        return safe
    return {}


def _success_message(action: str) -> str:
    messages = {
        "register": "资源已注册；已写入服务状态，未执行业务写入。",
        "edit": "资源已编辑；已写入服务状态，未执行业务写入。",
        "enable": "资源已启用；已写入服务状态，未执行业务写入。",
        "disable": "资源已停用；已写入服务状态，未执行业务写入。",
        "delete": "资源已删除；已写入服务状态，未执行业务写入。",
        "check-resource": "服务状态检查已完成；已写入运行状态，未执行业务写入。",
        "check-all": "全部资源检查已完成；已写入运行状态，未执行业务写入。",
        "login-check": "登录状态检查已完成；已写入服务状态，未执行业务写入。",
        "cancel-login-check": "登录状态检查已取消；已写入服务状态，未执行业务写入。",
        "service-check": "端口管理服务检查已完成；未执行业务写入。",
        "list-resources": "端口资源列表读取完成；未写入服务状态或业务数据。",
        "resource-detail": "资源详情读取完成；未写入服务状态或业务数据。",
        "storage-plan": "存储盘点计划已生成；未删除数据或执行业务写入。",
        "occupancy": "资源占用情况读取完成；未写入服务状态或业务数据。",
    }
    return messages.get(action, "端口管理操作已完成；请查看结果详情。")


def _invoke_raw(action: str, resource_id: str, timeout: int, params: dict[str, Any] | None = None) -> dict[str, Any]:
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
    if action == "login-resource":
        return _result(
            False,
            status="waiting-manual",
            result=None,
            error_code="LOGIN_INTERACTIVE_REQUIRED",
            message="正式登录需要在当前 PowerShell 会话中安全输入凭据；请继续按登录提示操作。",
            evidence={"publicAction": public_action, "interactiveEntry": True},
            needs_manual_action=True,
        )
    params = params if isinstance(params, dict) else {}
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
    if action in {"resource-detail", "check-resource", "storage-plan", "occupancy", "login-check", "cancel-login-check", "open-resource", "login-resource", "edit", "enable", "disable", "delete"} and resource_id:
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
    argument_flags = {
        "resourceName": "-ResourceName", "hostName": "-HostName", "port": "-Port",
        "connectionMode": "-ConnectionMode", "browserExecutable": "-BrowserExecutable",
        "browserProfileDirectory": "-BrowserProfileDirectory", "startUrl": "-StartUrl",
        "notes": "-Notes", "confirmationText": "-ConfirmationText",
        "leaseId": "-LeaseId", "taskRef": "-TaskRef",
    }
    for key, flag in argument_flags.items():
        if params.get(key) not in (None, ""):
            command.extend([flag, str(params[key])])
    if params.get("disabled") is True:
        command.append("-Disabled")
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
    failure_message = str(envelope.get("message") or "端口管理操作失败。")[:300]
    failure_code = str(envelope.get("errorCode") or "PORT_MANAGER_FAILED")
    if action == "storage-plan" and "Sum" in failure_message:
        failure_code = "PROFILE_NOT_CONFIGURED"
        failure_message = "该资源没有可盘点的 Profile 数据；未执行清理，也未删除任何文件。"
    return _result(
        success,
        status="succeeded" if success else "failed",
        result=_safe_payload(action, envelope.get("data")),
        error_code=None if success else failure_code,
        message=(
            "端口管理只读动作与结果回查成功。"
            if success
            else failure_message
        ),
        evidence={
            "publicAction": public_action,
            "exitCode": completed.returncode,
            "singleJsonDocument": True,
            "writeLevel": "service-state-write" if action in {"check-resource", "check-all", "register", "edit", "enable", "disable", "delete", "login-check", "cancel-login-check", "open-resource", "login-resource"} else "pure-read",
        },
        service_state_writes_executed=success and action in {"check-resource", "check-all", "register", "edit", "enable", "disable", "delete", "login-check", "cancel-login-check", "open-resource", "login-resource"},
    )


def _invoke(action: str, resource_id: str, timeout: int, params: dict[str, Any] | None = None) -> dict[str, Any]:
    result = _invoke_raw(action, resource_id, timeout, params)
    if result.get("success"):
        result["message"] = _success_message(action)
        evidence = result.get("evidence")
        if isinstance(evidence, dict):
            evidence["writeLevel"] = (
                "service-state-write"
                if action in {"check-resource", "check-all", "register", "edit", "enable", "disable", "delete", "login-check", "cancel-login-check", "open-resource", "login-resource"}
                else "pure-read"
            )
    return result


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
        # The scheduler protocol names user inputs ``parameters``; keep
        # ``params`` as a backward-compatible adapter alias for older callers.
        output = _invoke(action, resource_id, timeout, payload.get("parameters", payload.get("params")))
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
