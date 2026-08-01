from __future__ import annotations

from typing import Any

from .models import now_iso
from .scheduler_models import STATE_BLOCKED
from .scheduler_store import SchedulerStore
from .scheduler_view import public_task


def finish_blocked(
    store: SchedulerStore,
    task: dict[str, Any],
    error_code: str,
    summary: str,
    next_action: str,
    *,
    retryable: bool,
) -> dict[str, Any]:
    task = store.transition(
        task,
        STATE_BLOCKED,
        stage="preflight",
        summary=summary,
        error_code=error_code,
        next_action=next_action,
        retryable=retryable,
        extra={"finishedAt": now_iso()},
    )
    return public_task(task, include_result=True)
