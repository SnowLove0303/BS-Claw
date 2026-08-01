from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any


ALLOWED_CONCLUSIONS = {"可用", "不可用", "需登录", "需修复", "未验证"}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat()


@dataclass(frozen=True)
class CommandResult:
    success: bool
    data: Any
    message: str = ""
    error_code: str = ""


def envelope(
    action: str,
    success: bool,
    summary: str,
    data: Any,
    *,
    error_code: str = "",
    next_action: str = "",
    overall_state: str = "",
) -> dict[str, Any]:
    return {
        "success": success,
        "action": action,
        "summary": summary,
        "overallState": overall_state or ("可用" if success else "不可用"),
        "checkedAt": now_iso(),
        "data": data,
        "errorCode": error_code or None,
        "nextAction": next_action or ("无需处理" if success else "请按提示检查后重试"),
    }
