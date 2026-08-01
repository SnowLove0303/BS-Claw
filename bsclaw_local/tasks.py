from __future__ import annotations

import json
import uuid
from pathlib import Path
from typing import Any

from .models import now_iso


class TaskStore:
    def __init__(self, data_root: Path) -> None:
        self.data_root = data_root
        self.path = data_root / "task-records.jsonl"

    def append(
        self,
        action: str,
        status: str,
        summary: str,
        *,
        module_id: str = "",
        resource_id: str = "",
        write_level: str = "pure-read",
        business_writes_executed: bool = False,
    ) -> dict[str, Any]:
        self.data_root.mkdir(parents=True, exist_ok=True)
        record = {
            "taskId": f"TASK-{uuid.uuid4().hex[:10].upper()}",
            "action": action,
            "status": status,
            "summary": summary[:200],
            "moduleId": module_id or None,
            "resourceId": resource_id or None,
            "writeLevel": write_level,
            "businessWritesExecuted": bool(business_writes_executed),
            "createdAt": now_iso(),
        }
        with self.path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")))
            stream.write("\n")
        return record

    def recent(self, limit: int = 20) -> list[dict[str, Any]]:
        if not self.path.is_file():
            return []
        records: list[dict[str, Any]] = []
        with self.path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(item, dict):
                    records.append(
                        {
                            "taskId": str(item.get("taskId") or ""),
                            "action": str(item.get("action") or ""),
                            "status": str(item.get("status") or ""),
                            "summary": str(item.get("summary") or "")[:200],
                            "createdAt": str(item.get("createdAt") or ""),
                            "moduleId": str(item.get("moduleId") or ""),
                            "resourceId": str(item.get("resourceId") or ""),
                            "writeLevel": str(item.get("writeLevel") or "pure-read"),
                            "businessWritesExecuted": bool(
                                item.get("businessWritesExecuted")
                            ),
                        }
                    )
        return records[-limit:][::-1]
