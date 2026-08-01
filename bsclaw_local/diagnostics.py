from __future__ import annotations

from typing import Any


from .capabilities import BUSINESS_TYPES, SERVICE_TYPES


def build_diagnostic(snapshot: dict[str, Any], modules: list[dict[str, Any]]) -> dict[str, Any]:
    normal: list[str] = []
    abnormal: list[str] = []
    unverified: list[str] = []
    manual: list[str] = []

    port_state = snapshot.get("portManager", {}).get("state")
    if port_state == "可用":
        normal.append("端口管理正式入口可读")
    else:
        abnormal.append("端口管理当前不可用")

    huice = snapshot.get("huice", {})
    huice_state = huice.get("state")
    if huice_state == "可用":
        normal.append("慧策资源中存在有效登录与只读接口证据")
    elif huice_state == "需登录":
        manual.append("慧策资源需要进入菜单 3，选择对应资源后完成正式登录")
    elif huice_state == "需修复":
        abnormal.append("慧策资源状态维护链路需要修复")
    else:
        unverified.append("慧策资源尚无足够的新鲜状态证据")

    service_modules = [item for item in modules if item.get("type") in SERVICE_TYPES]
    business_modules = [item for item in modules if item.get("type") in BUSINESS_TYPES]
    other_modules = [
        item for item in modules if item.get("type") not in SERVICE_TYPES | BUSINESS_TYPES
    ]
    _classify_modules(service_modules, "服务插件", normal, abnormal, unverified)
    _classify_modules(business_modules, "业务模块", normal, abnormal, unverified)
    _classify_modules(other_modules, "未分类模块", normal, abnormal, unverified)
    if not service_modules:
        unverified.append("未发现正式服务插件")
    if not business_modules:
        unverified.append("未发现正式业务执行模块")

    resources = huice.get("resources") if isinstance(huice.get("resources"), list) else []
    resource_counts = {
        "total": len(resources),
        "ready": 0,
        "unverified": 0,
        "loginRequired": 0,
        "repairRequired": 0,
        "unavailable": 0,
    }
    resource_issues: list[dict[str, Any]] = []
    state_to_count = {
        "可用": "ready",
        "未验证": "unverified",
        "需登录": "loginRequired",
        "需修复": "repairRequired",
        "不可用": "unavailable",
    }
    for item in resources:
        state = str(item.get("state") or "未验证")
        key = state_to_count.get(state, "unverified")
        resource_counts[key] += 1
        if key != "ready":
            resource_issues.append(
                {
                    "resourceId": item.get("resourceId"),
                    "state": state,
                    "summary": item.get("summary"),
                    "checkedAt": item.get("checkedAt"),
                }
            )

    if not resources:
        unverified.append("当前端口资源列表为空")

    system_counts = {
        "normal": len(normal),
        "abnormal": len(abnormal),
        "unverified": len(unverified),
        "manualAction": len(manual),
    }
    return {
        "normal": normal,
        "abnormal": abnormal,
        "unverified": unverified,
        "manualAction": manual,
        "counts": system_counts,
        "system": {
            "normal": normal,
            "abnormal": abnormal,
            "unverified": unverified,
            "manualAction": manual,
            "counts": system_counts,
        },
        "resources": {
            "counts": resource_counts,
            "issues": resource_issues,
        },
    }


def _classify_modules(
    modules: list[dict[str, Any]],
    label: str,
    normal: list[str],
    abnormal: list[str],
    unverified: list[str],
) -> None:
    for module in modules:
        name = str(module.get("name") or "未命名")
        state = module.get("state")
        if state == "已注册" and module.get("entryAvailable") is True:
            normal.append(f"{label} {name} 已接入并可以检查")
        elif state == "资料已发现/未接入执行":
            unverified.append(f"{name} 尚未接入执行能力")
        elif state == "未接入执行":
            abnormal.append(f"{name} 尚未完成接入，当前不能执行")
        else:
            unverified.append(f"{name} 状态未验证")
