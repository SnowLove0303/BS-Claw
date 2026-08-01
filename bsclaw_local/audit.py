from __future__ import annotations

from typing import Any

from .models import ALLOWED_CONCLUSIONS


def build_audit(
    target: str,
    audit_type: str,
    snapshot: dict[str, Any],
    modules: list[dict[str, Any]],
    diagnostic: dict[str, Any],
    *,
    business_writes_enabled: bool,
) -> dict[str, Any]:
    if target == "端口管理":
        state = snapshot.get("portManager", {}).get("state", "不可用")
        conclusion = "可用" if state == "可用" else "需修复"
    elif target == "慧策资源":
        state = snapshot.get("huice", {}).get("state", "未验证")
        conclusion = state if state in ALLOWED_CONCLUSIONS else "未验证"
    elif target == "统一调度":
        registered = [
            module
            for module in modules
            if module.get("state") == "已注册"
            and module.get("entryAvailable") is True
        ]
        conclusion = "可用" if registered else "未验证"
    else:
        if diagnostic["abnormal"]:
            conclusion = "需修复"
        elif diagnostic["manualAction"]:
            conclusion = "需登录"
        elif diagnostic["unverified"]:
            conclusion = "未验证"
        else:
            conclusion = "可用"
    if conclusion not in ALLOWED_CONCLUSIONS:
        conclusion = "未验证"
    evidence = {
        "normal": diagnostic["normal"],
        "abnormal": diagnostic["abnormal"],
        "unverified": diagnostic["unverified"],
        "manualAction": diagnostic["manualAction"],
    }
    if target == "统一调度" and conclusion != "可用":
        evidence["unverified"] = list(evidence["unverified"]) + [
            "当前没有可用于真实执行验收的正式注册模块。"
        ]
    return {
        "target": target,
        "auditType": audit_type,
        "conclusion": conclusion,
        "evidence": evidence,
        "sensitiveValuesIncluded": False,
        "businessWritesExecuted": False,
    }
