from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any


SNAPSHOT_FIELDS = (
    "resourceId",
    "resourceName",
    "port",
    "enabled",
    "connectionStatus",
    "browserStatus",
    "pageStatus",
    "loginStatus",
    "apiStatus",
    "confidence",
    "checkedAt",
    "snapshotAt",
    "freshness",
    "statusSource",
    "nextAction",
    "occupancy",
    "lease",
)


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


def _freshness(checked_at: str, snapshot_at: str, max_age_seconds: int) -> str:
    checked = _parse_time(checked_at)
    if checked is None:
        return "never-checked"
    age = datetime.now().astimezone() - checked.astimezone()
    if age < -timedelta(minutes=5):
        return "invalid-time"
    return "fresh" if age <= timedelta(seconds=max_age_seconds) else "stale"


def _status_source(source: dict[str, Any], checked_at: str) -> str:
    explicit = _text(source.get("statusSource") or source.get("source"))
    if explicit:
        return explicit
    return "PortManager public JSON check" if checked_at else "PortManager public JSON resource definition"


def _next_action(login: str, api: str, freshness: str, enabled: bool) -> str:
    if not enabled:
        return "enable-resource"
    normalized_login = login.lower()
    normalized_api = api.lower()
    if normalized_login in {"logged-in", "authenticated", "已登录", "登录有效"} and normalized_api in {
        "logged-in-api-ready",
        "200",
        "ok",
        "已就绪",
    } and freshness == "fresh":
        return "reuse-resource"
    if normalized_login in {"login-required", "session-expired", "未登录", "需要登录"}:
        return "login-resource"
    if freshness in {"stale", "never-checked", "invalid-time"}:
        return "check-resource"
    return "inspect-resource-state"


def _next_action_label(action: str) -> str:
    return {
        "enable-resource": "启用资源",
        "reuse-resource": "复用已登录资源",
        "login-resource": "进入正式登录",
        "check-resource": "重新检查状态",
        "inspect-resource-state": "查看资源状态",
    }.get(action, "查看资源状态")


def project_resource(
    resource: dict[str, Any],
    *,
    snapshot_at: str = "",
    max_age_seconds: int = 900,
) -> dict[str, Any]:
    """Create the single sanitized ResourceSnapshot projection.

    Input is expected to come from the public PortManager JSON adapter. This
    function never opens a database, reads a Profile, or resolves credentials.
    """
    source = resource if isinstance(resource, dict) else {}
    status = source.get("lastStatus")
    if not isinstance(status, dict):
        status = source.get("status") if isinstance(source.get("status"), dict) else {}
    checked_at = _text(
        source.get("checkedAt")
        or status.get("checkedAt")
        or status.get("loginCheckedAt")
        or status.get("lastCheckedAt")
    )
    captured_at = _text(snapshot_at or source.get("snapshotAt") or status.get("snapshotAt"))
    login = _text(source.get("loginStatus") or status.get("loginStatus"))
    api = _text(
        source.get("apiStatus")
        or source.get("loginApiProbeStatus")
        or status.get("apiStatus")
        or status.get("loginApiProbeStatus")
    )
    connection = _text(source.get("connectionStatus") or status.get("connectionStatus"))
    page = _text(
        source.get("pageStatus")
        or source.get("pageMatchStatus")
        or status.get("pageStatus")
        or status.get("pageMatchStatus")
    )
    browser = _text(source.get("browserStatus") or status.get("browserStatus") or connection)
    confidence = _text(
        source.get("confidence")
        or source.get("loginConfidence")
        or status.get("confidence")
        or status.get("loginConfidence")
        or "unknown"
    )
    enabled = bool(source.get("enabled", True))
    freshness = _freshness(checked_at, captured_at, max_age_seconds)
    occupancy = source.get("occupancy")
    if not isinstance(occupancy, dict):
        occupancy = {
            "active": bool(source.get("currentOccupancy") or status.get("currentOccupancy")),
            "taskRef": source.get("taskRef") or status.get("taskRef"),
            "count": source.get("currentOccupancy") or status.get("currentOccupancy") or 0,
        }
    lease = source.get("lease")
    if not isinstance(lease, dict):
        lease = {
            "active": bool(source.get("leaseId") or status.get("leaseId")),
            "leaseId": source.get("leaseId") or status.get("leaseId"),
        }
    snapshot = {
        "resourceId": source.get("resourceId"),
        "resourceName": source.get("resourceName") or source.get("name"),
        "name": source.get("name") or source.get("resourceName"),
        "platform": source.get("platform") or source.get("platformName"),
        "port": source.get("port"),
        "enabled": enabled,
        "connectionStatus": connection,
        "browserStatus": browser,
        "pageStatus": page,
        "loginStatus": login,
        "apiStatus": api,
        "confidence": confidence,
        "checkedAt": checked_at or None,
        "snapshotAt": captured_at or None,
        "freshness": freshness,
        "statusSource": _status_source(source, checked_at),
        "nextAction": _next_action(login, api, freshness, enabled),
        "nextActionLabel": _next_action_label(_next_action(login, api, freshness, enabled)),
        "occupancy": occupancy,
        "lease": lease,
    }
    for key in ("state", "summary", "fresh", "ageSeconds", "monitorFreshness", "watcherState"):
        if key in source:
            snapshot[key] = source[key]
    snapshot["lastStatus"] = status
    return snapshot


def project_resources(resources: list[dict[str, Any]], *, snapshot_at: str = "") -> list[dict[str, Any]]:
    return [project_resource(item, snapshot_at=snapshot_at) for item in resources if isinstance(item, dict)]
