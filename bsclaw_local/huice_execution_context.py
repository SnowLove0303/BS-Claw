from __future__ import annotations

from dataclasses import dataclass, asdict
from typing import Any


@dataclass(frozen=True)
class HuiceExecutionContext:
    """Sanitized resource context injected into a business plugin.

    It is intentionally a value object: no database connection, Profile path,
    credential value, browser handle, lease mutator, or arbitrary HTTP client
    is exposed to the plugin.
    """

    resource_id: str
    resource_name: str | None
    port: int | str | None
    connection_status: str | None
    browser_status: str | None
    page_status: str | None
    login_status: str | None
    api_status: str | None
    confidence: str | None
    checked_at: str | None
    freshness: str | None
    status_source: str | None
    next_action: str | None
    service_handle: str = "port-manager-public-json"

    @classmethod
    def from_resource(cls, resource: dict[str, Any] | None) -> "HuiceExecutionContext | None":
        if not isinstance(resource, dict):
            return None
        return cls(
            resource_id=str(resource.get("resourceId") or ""),
            resource_name=resource.get("resourceName") or resource.get("name"),
            port=resource.get("port"),
            connection_status=resource.get("connectionStatus"),
            browser_status=resource.get("browserStatus"),
            page_status=resource.get("pageStatus"),
            login_status=resource.get("loginStatus"),
            api_status=resource.get("apiStatus") or resource.get("loginApiProbeStatus"),
            confidence=resource.get("confidence") or resource.get("loginConfidence"),
            checked_at=resource.get("checkedAt"),
            freshness=resource.get("freshness"),
            status_source=resource.get("statusSource"),
            next_action=resource.get("nextAction"),
        )

    def public_dict(self) -> dict[str, Any]:
        payload = asdict(self)
        payload.update(
            {
                "resourceId": payload.pop("resource_id"),
                "resourceName": payload.pop("resource_name"),
                "connectionStatus": payload.pop("connection_status"),
                "browserStatus": payload.pop("browser_status"),
                "pageStatus": payload.pop("page_status"),
                "loginStatus": payload.pop("login_status"),
                "apiStatus": payload.pop("api_status"),
                "checkedAt": payload.pop("checked_at"),
                "statusSource": payload.pop("status_source"),
                "nextAction": payload.pop("next_action"),
            }
        )
        return payload

