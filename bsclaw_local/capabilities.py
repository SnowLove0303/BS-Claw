from __future__ import annotations

from dataclasses import dataclass
from typing import Any


WRITE_LEVEL_PURE_READ = "pure-read"
WRITE_LEVEL_SERVICE_STATE = "service-state-write"
WRITE_LEVEL_BUSINESS = "business-write"
WRITE_LEVELS = {
    WRITE_LEVEL_PURE_READ,
    WRITE_LEVEL_SERVICE_STATE,
    WRITE_LEVEL_BUSINESS,
}

SERVICE_TYPES = {"service", "resource-service", "huice-resource-service"}
BUSINESS_TYPES = {"workflow", "business-module"}


def action_write_level(action: dict[str, Any]) -> str:
    declared = str(action.get("writeLevel") or "").strip()
    if declared in WRITE_LEVELS:
        return declared
    return (
        WRITE_LEVEL_BUSINESS
        if str(action.get("mode") or "") == "write"
        else WRITE_LEVEL_PURE_READ
    )


@dataclass(frozen=True)
class UserCapability:
    module_id: str
    module_name: str
    module_type: str
    capability_id: str
    action: str
    display_name: str
    category: str
    write_level: str
    requires_resource: bool
    requires_login_gate: bool
    requires_confirmation: bool
    confirmation_text: str
    progress_text: str
    success_view: str
    failure_next_action: str
    retryable: bool
    cancellable: bool
    recoverable: bool
    dispatch: str
    resource_selection_mode: str
    concurrency_policy: str
    resource_execution_policy: str

    @classmethod
    def from_manifest(
        cls, manifest: dict[str, Any], payload: dict[str, Any]
    ) -> "UserCapability":
        action = str(payload.get("action") or payload.get("id") or "")
        requires_resource = bool(payload.get("requiresResourceSelection"))
        selection_mode = str(
            payload.get("resourceSelectionMode")
            or ("all" if action == "check-all" else "single" if requires_resource else "none")
        )
        execution_policy = str(
            payload.get("resourceExecutionPolicy")
            or ("cross-resource-parallel" if selection_mode == "all" else "same-resource-exclusive" if selection_mode == "single" else "policy-pending")
        )
        return cls(
            module_id=str(manifest.get("moduleId") or ""),
            module_name=str(manifest.get("name") or ""),
            module_type=str(manifest.get("type") or "business-module"),
            capability_id=str(payload.get("id") or ""),
            action=action,
            display_name=str(payload.get("displayName") or ""),
            category=str(payload.get("category") or "查看"),
            write_level=str(payload.get("writeLevel") or WRITE_LEVEL_PURE_READ),
            requires_resource=requires_resource,
            requires_login_gate=bool(payload.get("requiresLoginGate")),
            requires_confirmation=bool(payload.get("requiresConfirmation")),
            confirmation_text=str(payload.get("confirmationText") or ""),
            progress_text=str(payload.get("progressText") or "正在处理"),
            success_view=str(payload.get("successResultView") or "summary"),
            failure_next_action=str(payload.get("failureNextAction") or "请重试"),
            retryable=bool(payload.get("retryable")),
            cancellable=bool(payload.get("cancellable")),
            recoverable=bool(payload.get("recoverable")),
            dispatch=str(payload.get("dispatch") or "scheduler"),
            resource_selection_mode=selection_mode,
            concurrency_policy=str(
                payload.get("concurrencyPolicy")
                or ("per-resource" if selection_mode in {"single", "all"} else "none")
            ),
            resource_execution_policy=execution_policy,
        )


def capabilities_for(manifest: dict[str, Any]) -> list[UserCapability]:
    raw = manifest.get("capabilities")
    if not isinstance(raw, list):
        return []
    return [
        UserCapability.from_manifest(manifest, item)
        for item in raw
        if isinstance(item, dict)
    ]


class CapabilityCatalog:
    def __init__(self, registry: Any) -> None:
        self.registry = registry

    def all(self) -> list[UserCapability]:
        found: list[UserCapability] = []
        modules, _ = self.registry.scan()
        for module in modules:
            if module.valid and self.registry.entry_path(module).is_file():
                found.extend(capabilities_for(module.manifest))
        return found

    def get(self, module_id: str, capability_id: str) -> UserCapability:
        for capability in self.all():
            if (
                capability.module_id == module_id
                and capability.capability_id == capability_id
            ):
                return capability
        raise KeyError(f"未找到用户能力：{module_id}/{capability_id}")

    def module_name(self, module_id: str) -> str:
        for capability in self.all():
            if capability.module_id == module_id:
                return capability.module_name
        return "未接入模块" if module_id else "系统记录"
