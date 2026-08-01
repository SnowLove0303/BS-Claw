from __future__ import annotations

import json
from typing import Any

from .audit import build_audit
from .diagnostics import build_diagnostic
from .huice import HuiceAdapter
from .models import envelope
from .module_discovery import ModuleDiscovery
from .module_registry import ModuleRegistry
from .paths import ProjectPaths
from .port_manager import PortManagerAdapter
from .scheduler import UnifiedScheduler
from .scheduler_store import SchedulerStore
from .tasks import TaskStore


SERVICE_TYPES = {"service", "resource-service", "huice-resource-service"}
BUSINESS_TYPES = {"workflow", "business-module"}


class LocalApplication:
    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths
        self.port_manager = PortManagerAdapter(paths)
        self.huice = HuiceAdapter(paths)
        self.modules = ModuleDiscovery(paths)
        self.module_registry = ModuleRegistry(paths)
        self.tasks = TaskStore(paths.data_root)
        self.scheduler = UnifiedScheduler(SchedulerStore(paths.data_root), self.module_registry, self.port_manager)
        try:
            manifest = json.loads(paths.manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            manifest = {}
        self.business_writes_enabled = manifest.get("businessWritesEnabled") is True

    def snapshot(self) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        port_status = self.port_manager.service_status()
        snapshot = {
            "portManager": {key: value for key, value in port_status.items() if key != "resources"},
            "huice": self.huice.status_from_resources(port_status["resources"]),
        }
        return snapshot, self.modules.discover(snapshot)

    def execute(self, command: str, *, no_record: bool = False, target: str = "本地服务整体", audit_type: str = "状态审计", task_limit: int = 20) -> dict[str, Any]:
        if command == "tasks":
            records = self.tasks.recent(max(1, min(task_limit, 100)))
            return envelope("tasks", True, f"读取到 {len(records)} 条最近记录", records)
        if command == "resources":
            result = self.port_manager.list_resources()
            data = result.data if result.success else []
            output = envelope(command, result.success, result.message or "端口资源读取失败", data, error_code=result.error_code, next_action=_next_action(command, result.success, data))
            if not no_record:
                self.tasks.append(command, "成功" if result.success else "失败", output["summary"])
            return output

        snapshot, modules = self.snapshot()
        success = snapshot["portManager"]["state"] == "可用"
        overall_state = _overall_state(snapshot, modules)
        error_code = ""
        if command == "huice":
            data = snapshot["huice"]
            summary = data["summary"]
            success = data["state"] not in {"不可用", "需修复"}
            overall_state = data["state"]
            error_code = "" if success else "HUICE_RESOURCE_UNAVAILABLE"
        elif command == "modules":
            groups = registry_groups(modules)
            data = modules
            counts = groups["counts"]
            summary = f"服务插件 {counts['servicePlugins']} 个，业务模块 {counts['businessModules']} 个，资料/未接入 {counts['documentationOnly'] + counts['other']} 个"
            success = bool(modules)
            overall_state = "可用" if any(item.get("state") == "已注册" and item.get("entryAvailable") is True for item in groups["businessModules"]) else "未接入"
            error_code = "" if success else "MODULE_NOT_FOUND"
        elif command == "diagnose":
            data = build_diagnostic(snapshot, modules)
            counts = data["resources"]["counts"]
            summary = f"系统正常 {data['counts']['normal']} 项、异常 {data['counts']['abnormal']} 项、未验证 {data['counts']['unverified']} 项、需人工 {data['counts']['manualAction']} 项；资源可用 {counts['ready']} 项、未验证 {counts['unverified']} 项、需登录 {counts['loginRequired']} 项、需修复/不可用 {counts['repairRequired'] + counts['unavailable']} 项"
            success = not data["abnormal"]
            error_code = "" if success else "DIAGNOSTIC_ISSUES_FOUND"
        elif command == "audit":
            diagnostic = build_diagnostic(snapshot, modules)
            data = build_audit(target, audit_type, snapshot, modules, diagnostic, business_writes_enabled=self.business_writes_enabled)
            summary = f"{target}：{data['conclusion']}"
            success, overall_state = True, data["conclusion"]
        else:
            groups = registry_groups(modules)
            data = {"services": snapshot, "modules": modules, "registrySummary": groups["counts"]}
            summary = f"端口管理：{snapshot['portManager']['state']}；慧策资源：{snapshot['huice']['state']}；服务插件：{'已注册' if groups['servicePlugins'] else '未接入'}；业务模块：{'已注册' if groups['businessModules'] else '未接入'}"
            error_code = "" if success else "LOCAL_SERVICE_UNAVAILABLE"
        output = envelope(command, success, summary, data, error_code=error_code, next_action=_next_action(command, success, data, overall_state), overall_state=overall_state)
        if not no_record:
            self.tasks.append(command, "成功" if success else ("未验证" if command in {"audit", "diagnose"} else "失败"), summary)
        return output

    def menu(self) -> int:
        from .user_interface import UserConsole
        return UserConsole(self).run()


def registry_groups(modules: list[dict[str, Any]]) -> dict[str, Any]:
    services = [item for item in modules if item.get("type") in SERVICE_TYPES]
    business = [item for item in modules if item.get("type") in BUSINESS_TYPES]
    documentation = [item for item in modules if item.get("state") == "资料已发现/未接入执行" and item not in services and item not in business]
    other = [item for item in modules if item not in services and item not in business and item not in documentation]
    return {"servicePlugins": services, "businessModules": business, "documentationOnly": documentation, "other": other, "counts": {"servicePlugins": len(services), "businessModules": len(business), "documentationOnly": len(documentation), "other": len(other)}}


def _overall_state(snapshot: dict[str, Any], modules: list[dict[str, Any]]) -> str:
    port_state = snapshot.get("portManager", {}).get("state", "不可用")
    huice_state = snapshot.get("huice", {}).get("state", "未验证")
    if port_state != "可用" or huice_state in {"不可用", "需修复"}:
        return "需修复"
    if huice_state == "需登录":
        return "需登录"
    if huice_state != "可用":
        return "未验证"
    business = [item for item in modules if item.get("type") in BUSINESS_TYPES]
    return "可用" if any(item.get("state") == "已注册" and item.get("entryAvailable") is True for item in business) else "部分可用"


def _next_action(command: str, success: bool, data: Any, overall_state: str = "") -> str:
    if command == "status":
        return {
            "需登录": "进入菜单 3“慧策资源与登录状态”，选择对应资源后按提示重新检查或正式登录。",
            "需修复": "进入菜单 4“服务诊断”，根据异常提示处理后重新检查。",
            "未验证": "进入菜单 3检查慧策资源状态；尚未接入的业务模块不会显示执行入口。",
            "部分可用": "本地服务可以使用；当前没有可执行的业务模块。",
        }.get(overall_state, "本地服务已就绪")
    if command == "audit":
        return "审计对象当前可用" if isinstance(data, dict) and data.get("conclusion") == "可用" else "请处理审计摘要中的未验证或阻断项"
    if success:
        return "可按类型查看服务插件与业务模块；本阶段不执行业务写入" if command == "modules" else "可继续使用当前入口"
    return {
        "resources": "请检查 F 盘 Python 和端口管理入口。",
        "huice": "进入菜单 3检查资源；需要登录时选择对应资源并进入正式登录。",
        "modules": "当前没有可用模块；接入完成后会在模块列表中显示。",
    }.get(command, "请进入菜单 4查看异常和未验证项。")
