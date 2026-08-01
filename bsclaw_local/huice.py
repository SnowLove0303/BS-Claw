from __future__ import annotations

from typing import Any

from .paths import ProjectPaths


class HuiceAdapter:
    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths

    def status_from_resources(self, resources: list[dict[str, Any]]) -> dict[str, Any]:
        agent_available = self.paths.huice_entry.is_file()
        huice_resources = [
            item
            for item in resources
            if "慧策" in str(item.get("platform") or item.get("name") or "")
            or str(item.get("resourceId") or "").startswith("HCP-")
        ]
        ready = [item for item in huice_resources if item.get("state") == "可用"]
        login_required = [item for item in huice_resources if item.get("state") == "需登录"]
        repair = [item for item in huice_resources if item.get("state") == "需修复"]
        if not agent_available:
            state = "不可用"
            summary = "慧策登录适配器未发现"
        elif ready:
            state = "可用"
            summary = f"{len(ready)} 个慧策资源当前可用"
        elif login_required:
            state = "需登录"
            summary = f"{len(login_required)} 个慧策资源需要登录"
        elif repair:
            state = "需修复"
            summary = f"{len(repair)} 个慧策资源需要修复"
        elif huice_resources:
            state = "未验证"
            summary = "慧策资源已登记，但状态需要重新检查"
        else:
            state = "未验证"
            summary = "尚未登记慧策资源"
        return {
            "state": state,
            "summary": summary,
            "adapterAvailable": agent_available,
            "resourceCount": len(huice_resources),
            "readyCount": len(ready),
            "loginRequiredCount": len(login_required),
            "resources": huice_resources,
        }
