from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

from .models import CommandResult
from .paths import ProjectPaths
from .process_runner import run_powershell_interactive, run_powershell_json


FRESHNESS_SECONDS = 900


def _text(value: Any) -> str:
    return str(value or "").strip()


def _parse_time(value: Any) -> datetime | None:
    raw = _text(value)
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_fresh(value: Any) -> bool:
    checked = _parse_time(value)
    if checked is None or checked.tzinfo is None:
        return False
    age = datetime.now().astimezone() - checked.astimezone()
    return -timedelta(minutes=5) <= age <= timedelta(seconds=FRESHNESS_SECONDS)


def _state_for(resource: dict[str, Any], last: dict[str, Any]) -> tuple[str, str]:
    if not bool(resource.get("enabled", True)):
        return "不可用", "资源已停用"
    login = _text(last.get("loginStatus")).lower()
    api = _text(last.get("loginApiProbeStatus")).lower()
    confidence = _text(last.get("loginConfidence")).lower()
    fresh = _is_fresh(last.get("loginCheckedAt") or last.get("lastCheckedAt"))
    if login in {"login-required", "未登录", "需要登录", "登录已过期", "session-expired"}:
        return "需登录", "慧策会话需要登录"
    if login in {"已登录", "logged-in", "authenticated"} and api == "logged-in-api-ready":
        if confidence == "high" and fresh:
            return "可用", "登录和只读接口状态有效"
        return "未验证", "已有登录记录，但需要重新检查状态新鲜度"
    if _text(last.get("loginDetectionErrorCode")) or _text(last.get("watcherErrorCode")):
        return "需修复", "状态维护链路存在异常"
    return "未验证", "尚无足够的实时登录证据"


class PortManagerAdapter:
    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths

    def list_resources(self) -> CommandResult:
        result = run_powershell_json(
            self.paths.port_manager_entry,
            ["-Action", "List", "-OutputFormat", "Json", "-NonInteractive"],
        )
        if not result.success:
            return result
        raw_resources = result.data if isinstance(result.data, list) else []
        resources = [self._sanitize(item) for item in raw_resources if isinstance(item, dict)]
        return CommandResult(True, resources, f"读取到 {len(resources)} 个端口资源。")

    def service_status(self) -> dict[str, Any]:
        result = self.list_resources()
        if not result.success:
            return {
                "state": "不可用",
                "summary": result.message or "端口管理不可用",
                "resourceCount": 0,
                "errorCode": result.error_code or "PORT_MANAGER_UNAVAILABLE",
                "resources": [],
            }
        resources = result.data
        return {
            "state": "可用",
            "summary": f"端口管理可用，共 {len(resources)} 个资源",
            "resourceCount": len(resources),
            "errorCode": None,
            "resources": resources,
        }

    def check_resource(self, resource_id: str) -> CommandResult:
        return run_powershell_json(
            self.paths.port_manager_entry,
            [
                "-Action",
                "Check",
                "-ResourceId",
                resource_id,
                "-OutputFormat",
                "Json",
                "-NonInteractive",
            ],
            timeout_seconds=90,
        )

    def open_resource(self, resource_id: str) -> CommandResult:
        return run_powershell_json(
            self.paths.port_manager_entry,
            [
                "-Action",
                "Open",
                "-ResourceId",
                resource_id,
                "-TimeoutSeconds",
                "20",
                "-OutputFormat",
                "Json",
                "-NonInteractive",
            ],
            timeout_seconds=45,
        )

    def login_resource_interactive(self, resource_id: str) -> int:
        return run_powershell_interactive(
            self.paths.port_manager_entry,
            ["-Action", "HuiceLogin", "-ResourceId", resource_id],
        )

    def open_menu(self) -> int:
        return run_powershell_interactive(
            self.paths.port_manager_entry,
            ["-Action", "Menu"],
        )

    @staticmethod
    def _sanitize(resource: dict[str, Any]) -> dict[str, Any]:
        last = resource.get("lastStatus")
        last_status = last if isinstance(last, dict) else {}
        state, summary = _state_for(resource, last_status)
        checked_at = _text(
            last_status.get("loginCheckedAt") or last_status.get("lastCheckedAt")
        )
        return {
            "resourceId": _text(resource.get("resourceId")),
            "name": _text(resource.get("resourceName") or resource.get("platformName")),
            "platform": _text(resource.get("platformName") or resource.get("platformId")),
            "port": resource.get("port"),
            "enabled": bool(resource.get("enabled", True)),
            "state": state,
            "summary": summary,
            "connectionStatus": _text(last_status.get("connectionStatus")) or "未检查",
            "loginStatus": _text(last_status.get("loginStatus")) or "状态未知",
            "apiStatus": _text(last_status.get("loginApiProbeStatus")) or "未检查",
            "confidence": _text(last_status.get("loginConfidence")) or "unknown",
            "checkedAt": checked_at or None,
            "fresh": _is_fresh(checked_at),
            "needsCheck": state in {"未验证", "需修复"},
        }

    @staticmethod
    def sanitize_checked(
        payload: dict[str, Any], base_resource: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        resource = payload.get("resource")
        if not isinstance(resource, dict):
            resource = payload
        last = payload.get("status")
        if not isinstance(last, dict):
            last = payload.get("lastStatus")
        if not isinstance(last, dict):
            last = resource.get("lastStatus")
        last_status = last if isinstance(last, dict) else {}
        combined = dict(base_resource or {})
        for key, value in resource.items():
            if value not in (None, ""):
                combined[key] = value
        combined["lastStatus"] = last_status
        safe = PortManagerAdapter._sanitize(combined)
        safe["pageStatus"] = _text(
            last_status.get("pageStatus")
            or last_status.get("pageMatchStatus")
            or last_status.get("pageUrl")
        ) or "未检查"
        return safe

    @staticmethod
    def merge_resource_state(
        base: dict[str, Any], update: dict[str, Any]
    ) -> dict[str, Any]:
        """Merge a live check without losing registered resource facts."""
        merged = dict(base)
        fact_keys = {"resourceId", "name", "platform", "port", "enabled"}
        for key, value in update.items():
            if key in fact_keys and merged.get(key) not in (None, ""):
                continue
            if value not in (None, ""):
                merged[key] = value
        return merged
