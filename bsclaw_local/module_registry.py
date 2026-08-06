from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from .capabilities import WRITE_LEVELS, action_write_level, capabilities_for

from .paths import ProjectPaths


MODULE_ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9._-]{1,63}$")
MANIFEST_NAMES = (
    "bsclaw.module.json",
    "module.manifest.json",
    "selection-module.manifest.json",
    "bsclaw.service.json",
    "service.manifest.json",
)
SUPPORTED_RUNTIMES = {"python", "powershell"}
SUPPORTED_PLUGIN_TYPES = {
    "service",
    "resource-service",
    "huice-resource-service",
    "workflow",
    "business-module",
}
SUPPORTED_RESOURCE_POLICIES = {
    "none",
    "pending",
    "exclusive",
    "same-port-shared",
    "cross-port",
}
SUPPORTED_SELECTION_MODES = {"none", "single", "multi", "all"}
SUPPORTED_EXECUTION_POLICIES = {
    "same-resource-exclusive",
    "cross-resource-parallel",
    "serial",
    "policy-pending",
}


@dataclass(frozen=True)
class RegisteredModule:
    root: Path
    manifest: dict[str, Any]
    valid: bool
    errors: tuple[str, ...]

    @property
    def module_id(self) -> str:
        return str(self.manifest.get("moduleId") or "")


class ModuleRegistry:
    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths

    def scan(self) -> tuple[list[RegisteredModule], list[dict[str, Any]]]:
        modules: list[RegisteredModule] = []
        docs_only: list[dict[str, Any]] = []
        seen: set[Path] = set()
        for candidate in self._candidate_directories():
            resolved = candidate.resolve(strict=False)
            if resolved in seen or not resolved.is_dir():
                continue
            seen.add(resolved)
            manifest_path = next(
                (resolved / name for name in MANIFEST_NAMES if (resolved / name).is_file()),
                None,
            )
            if manifest_path is None:
                if (resolved / "README.md").is_file():
                    docs_only.append(
                        {
                            "moduleId": None,
                            "name": resolved.name,
                            "version": None,
                            "state": "资料已发现/未接入执行",
                            "summary": "目录中没有正式模块 manifest，不能提交执行任务",
                            "manifestValid": False,
                            "entryAvailable": False,
                            "supportedActions": [],
                            "requiresHuiceResource": None,
                            "businessWritesEnabled": None,
                            "riskLevel": "未声明",
                            "errorCode": "MODULE_MANIFEST_NOT_FOUND",
                        }
                    )
                continue
            try:
                payload = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
            except (OSError, json.JSONDecodeError):
                payload = {}
                errors = ["manifest 不是有效 UTF-8 JSON"]
            else:
                errors = self._validate(payload, resolved)
            modules.append(
                RegisteredModule(
                    root=resolved,
                    manifest=payload if isinstance(payload, dict) else {},
                    valid=not errors,
                    errors=tuple(errors),
                )
            )
        return modules, docs_only

    def find(self, module_id: str) -> RegisteredModule | None:
        modules, _ = self.scan()
        matches = [item for item in modules if item.module_id == module_id]
        if not matches:
            return None
        if len(matches) > 1:
            return replace(
                matches[0],
                valid=False,
                errors=tuple(
                    sorted(set((*matches[0].errors, "moduleId 在注册目录中重复")))
                ),
            )
        return matches[0]

    def describe(self) -> list[dict[str, Any]]:
        modules, docs_only = self.scan()
        output: list[dict[str, Any]] = []
        for item in modules:
            manifest = item.manifest
            entry = manifest.get("entry") if isinstance(manifest.get("entry"), dict) else {}
            actions = manifest.get("actions") if isinstance(manifest.get("actions"), list) else []
            output.append(
                {
                    "moduleId": item.module_id or None,
                    "type": str(manifest.get("type") or "business-module"),
                    "name": str(manifest.get("name") or item.root.name),
                    "version": str(manifest.get("version") or "") or None,
                    "state": (
                        "已注册"
                        if item.valid and self.entry_path(item).is_file()
                        else "未接入执行"
                    ),
                    "summary": (
                        "模块契约有效，可进入任务预检"
                        if item.valid and self.entry_path(item).is_file()
                        else "模块声明或执行入口不完整，不能执行"
                    ),
                    "manifestValid": item.valid,
                    "entryAvailable": bool(entry) and self.entry_path(item).is_file(),
                    "supportedActions": [
                        str(action.get("id"))
                        for action in actions
                        if isinstance(action, dict) and action.get("id")
                    ],
                    "userCapabilities": [
                        {
                            "id": capability.capability_id,
                            "displayName": capability.display_name,
                            "category": capability.category,
                            "writeLevel": capability.write_level,
                            "requiresResourceSelection": capability.requires_resource,
                            "resourceSelectionMode": capability.resource_selection_mode,
                            "concurrencyPolicy": capability.concurrency_policy,
                            "resourceExecutionPolicy": capability.resource_execution_policy,
                            "requiresLoginGate": capability.requires_login_gate,
                            "requiresConfirmation": capability.requires_confirmation,
                            "retryable": capability.retryable,
                            "cancellable": capability.cancellable,
                            "recoverable": capability.recoverable,
                        }
                        for capability in capabilities_for(manifest)
                    ],
                    "requiresHuiceResource": any(
                        bool(action.get("requiresHuiceResource"))
                        for action in actions
                        if isinstance(action, dict)
                    ),
                    "businessWritesEnabled": bool(
                        manifest.get("businessWritesEnabled")
                    ),
                    "riskLevel": str(manifest.get("riskLevel") or "未声明"),
                    "writesServiceState": bool(manifest.get("writesServiceState")),
                    "errorCode": None if item.valid else "MODULE_MANIFEST_INVALID",
                    "validationErrors": list(item.errors),
                }
            )
        output.extend(docs_only)
        return output

    @staticmethod
    def action(module: RegisteredModule, action_id: str) -> dict[str, Any] | None:
        actions = module.manifest.get("actions")
        if not isinstance(actions, list):
            return None
        return next(
            (
                action
                for action in actions
                if isinstance(action, dict) and action.get("id") == action_id
            ),
            None,
        )

    @staticmethod
    def entry_path(module: RegisteredModule) -> Path:
        entry = module.manifest.get("entry")
        relative = str(entry.get("path") or "") if isinstance(entry, dict) else ""
        return (module.root / relative).resolve(strict=False)

    def _candidate_directories(self) -> list[Path]:
        roots: list[Path] = []
        configured = os.environ.get("BSCLAW_MODULE_ROOTS", "")
        for value in configured.split(os.pathsep):
            if value.strip():
                path = Path(value.strip()).resolve(strict=False)
                if path.drive.upper() != "F:":
                    continue
                roots.append(path)
        roots.append(self.paths.repository_root / "modules")
        roots.append(self.paths.repository_root / "SelectionModule-Phase1")
        roots.append(self.paths.local_root / "services")
        configured_services = os.environ.get("BSCLAW_SERVICE_ROOTS", "")
        for value in configured_services.split(os.pathsep):
            if value.strip():
                path = Path(value.strip()).resolve(strict=False)
                if path.drive.upper() == "F:":
                    roots.append(path)
        candidates: list[Path] = []
        for root in roots:
            if not root.is_dir():
                continue
            if any((root / name).is_file() for name in MANIFEST_NAMES) or (
                root / "README.md"
            ).is_file():
                candidates.append(root)
            else:
                candidates.extend(path for path in root.iterdir() if path.is_dir())
        return candidates

    def _validate(self, payload: Any, root: Path) -> list[str]:
        if not isinstance(payload, dict):
            return ["manifest 根节点必须是对象"]
        errors: list[str] = []
        if payload.get("schemaVersion") != 1:
            errors.append("schemaVersion 必须为 1")
        module_id = str(payload.get("moduleId") or "")
        if not MODULE_ID_PATTERN.fullmatch(module_id):
            errors.append("moduleId 格式无效")
        for field in ("name", "version", "riskLevel"):
            if not str(payload.get(field) or "").strip():
                errors.append(f"缺少 {field}")
        plugin_type = str(payload.get("type") or "business-module")
        if plugin_type not in SUPPORTED_PLUGIN_TYPES:
            errors.append("type 不受支持")
        if not isinstance(payload.get("businessWritesEnabled"), bool):
            errors.append("businessWritesEnabled 必须为布尔值")
        if plugin_type in {"service", "resource-service", "huice-resource-service"} and not isinstance(
            payload.get("writesServiceState"), bool
        ):
            errors.append("服务插件必须声明 writesServiceState")
        if plugin_type in {"service", "resource-service", "huice-resource-service"}:
            prohibited = payload.get("prohibitedDirectAccess")
            if not isinstance(prohibited, list) or not prohibited:
                errors.append("服务插件必须声明 prohibitedDirectAccess")
        entry = payload.get("entry")
        if not isinstance(entry, dict):
            errors.append("缺少 entry")
        else:
            runtime = str(entry.get("runtime") or "")
            if runtime not in SUPPORTED_RUNTIMES:
                errors.append("entry.runtime 不受支持")
            relative = str(entry.get("path") or "")
            target = (root / relative).resolve(strict=False)
            try:
                target.relative_to(root.resolve(strict=False))
            except ValueError:
                errors.append("entry.path 超出模块目录")
            if not relative:
                errors.append("缺少 entry.path")
        actions = payload.get("actions")
        if not isinstance(actions, list) or not actions:
            errors.append("至少声明一个 action")
        else:
            seen: set[str] = set()
            for action in actions:
                if not isinstance(action, dict):
                    errors.append("action 必须是对象")
                    continue
                action_id = str(action.get("id") or "")
                if not MODULE_ID_PATTERN.fullmatch(action_id) or action_id in seen:
                    errors.append("action.id 缺失、重复或格式无效")
                seen.add(action_id)
                if str(action.get("mode") or "") not in {"read-only", "service-state-write", "write"}:
                    errors.append(f"{action_id or 'action'} 缺少有效 mode")
                if action_write_level(action) not in WRITE_LEVELS:
                    errors.append(f"{action_id or 'action'} 缺少有效 writeLevel")
                if not isinstance(action.get("requiresHuiceResource"), bool):
                    errors.append(
                        f"{action_id or 'action'} requiresHuiceResource 必须为布尔值"
                    )
                if (
                    action_write_level(action) == "business-write"
                    and payload.get("businessWritesEnabled") is not True
                ):
                    errors.append(
                        f"{action_id or 'action'} 声明写入但模块未启用业务写入"
                    )
                selection_mode = str(action.get("resourceSelectionMode") or "none")
                execution_policy = str(action.get("resourceExecutionPolicy") or "policy-pending")
                if plugin_type in {"workflow", "business-module"} and "resourceSelectionMode" not in action:
                    errors.append(f"{action_id or 'action'} 缺少 resourceSelectionMode")
                if plugin_type in {"workflow", "business-module"} and "resourceExecutionPolicy" not in action:
                    errors.append(f"{action_id or 'action'} 缺少 resourceExecutionPolicy")
                if selection_mode not in SUPPORTED_SELECTION_MODES:
                    errors.append(f"{action_id or 'action'} resourceSelectionMode 无效")
                if execution_policy not in SUPPORTED_EXECUTION_POLICIES:
                    errors.append(f"{action_id or 'action'} resourceExecutionPolicy 无效")
                if selection_mode != "none" and execution_policy == "policy-pending":
                    errors.append(f"{action_id or 'action'} 不得使用未决资源执行策略")
                if selection_mode == "none" and execution_policy != "policy-pending":
                    errors.append(f"{action_id or 'action'} 无资源动作不得声明资源执行策略")
                inputs = action.get("inputs")
                if inputs is not None and not isinstance(inputs, list):
                    errors.append(f"{action_id or 'action'} inputs 必须为数组")
                policy = str(action.get("resourcePolicy") or "")
                if policy not in SUPPORTED_RESOURCE_POLICIES:
                    errors.append(f"{action_id or 'action'} 缺少有效 resourcePolicy")
                timeout = action.get("timeoutSeconds", 60)
                if not isinstance(timeout, int) or not 1 <= timeout <= 3600:
                    errors.append(f"{action_id or 'action'} timeoutSeconds 无效")
                result_check = action.get("resultCheck")
                if result_check is not None:
                    if not isinstance(result_check, dict) or result_check.get("mode") not in {
                        "plugin",
                        "result-contract",
                    }:
                        errors.append(f"{action_id or 'action'} resultCheck.mode 无效")
                    elif result_check.get("mode") == "plugin" and not str(
                        result_check.get("action") or ""
                    ):
                        errors.append(f"{action_id or 'action'} 缺少回查 action")
                    elif result_check.get("mode") == "result-contract" and not isinstance(
                        result_check.get("requiredFields"), list
                    ):
                        errors.append(f"{action_id or 'action'} 缺少结果契约字段")
        capabilities = payload.get("capabilities")
        if capabilities is not None:
            if not isinstance(capabilities, list):
                errors.append("capabilities 必须为数组")
            else:
                action_ids = {
                    str(item.get("id") or "")
                    for item in actions or []
                    if isinstance(item, dict)
                }
                for capability in capabilities:
                    if not isinstance(capability, dict):
                        errors.append("capability 必须是对象")
                        continue
                    capability_id = str(capability.get("id") or "")
                    if not capability_id or not str(capability.get("displayName") or ""):
                        errors.append("capability 缺少 id 或 displayName")
                    if str(capability.get("writeLevel") or "") not in WRITE_LEVELS:
                        errors.append(f"{capability_id or 'capability'} writeLevel 无效")
                    for field in (
                        "requiresResourceSelection",
                        "requiresLoginGate",
                        "requiresConfirmation",
                        "retryable",
                        "cancellable",
                        "recoverable",
                    ):
                        if not isinstance(capability.get(field), bool):
                            errors.append(
                                f"{capability_id or 'capability'} {field} 必须为布尔值"
                            )
                    for field in (
                        "category",
                        "progressText",
                        "successResultView",
                        "failureNextAction",
                    ):
                        if not str(capability.get(field) or "").strip():
                            errors.append(
                                f"{capability_id or 'capability'} 缺少 {field}"
                            )
                    if capability.get("requiresConfirmation") is True and not str(
                        capability.get("confirmationText") or ""
                    ).strip():
                        errors.append(
                            f"{capability_id or 'capability'} 缺少 confirmationText"
                        )
                    dispatch = str(capability.get("dispatch") or "scheduler")
                    action_id = str(capability.get("action") or capability_id)
                    if dispatch == "scheduler" and action_id not in action_ids:
                        errors.append(f"{capability_id or 'capability'} 未关联正式 action")
        return sorted(set(errors))
