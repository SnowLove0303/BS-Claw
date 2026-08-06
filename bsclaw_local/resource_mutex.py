from __future__ import annotations

import json
import os
import time
import ctypes
from pathlib import Path


class ResourceMutex:
    """Cross-process per-resource lock stored only in re-creatable scheduler data."""

    def __init__(self, root: Path, resource_id: str, task_id: str) -> None:
        safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in resource_id)
        self.path = root / "resource-locks" / f"{safe}.lock"
        self.task_id = task_id
        self.held = False

    @staticmethod
    def _process_start_token(pid: int) -> int | None:
        """Return a stable Windows process-start token for PID reuse checks."""
        if pid <= 0 or os.name != "nt":
            return None
        handle = ctypes.windll.kernel32.OpenProcess(0x0400, False, pid)
        if not handle:
            return None
        try:
            created = ctypes.c_ulonglong()
            exited = ctypes.c_ulonglong()
            kernel = ctypes.c_ulonglong()
            user = ctypes.c_ulonglong()
            ok = ctypes.windll.kernel32.GetProcessTimes(
                handle,
                ctypes.byref(created),
                ctypes.byref(exited),
                ctypes.byref(kernel),
                ctypes.byref(user),
            )
            return int(created.value) if ok else None
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)

    @classmethod
    def _alive(cls, pid: int, start_token: int | None = None) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        if start_token is None:
            return True
        current = cls._process_start_token(pid)
        return current is not None and current == int(start_token)

    def acquire(self) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "taskId": self.task_id,
            "pid": os.getpid(),
            "processStartToken": self._process_start_token(os.getpid()),
            "acquiredAt": time.time(),
        }
        try:
            fd = os.open(str(self.path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as stream:
                json.dump(payload, stream)
            self.held = True
            return True
        except FileExistsError:
            try:
                current = json.loads(self.path.read_text(encoding="utf-8"))
                if not self._alive(
                    int(current.get("pid") or 0),
                    current.get("processStartToken"),
                ):
                    self.path.unlink(missing_ok=True)
                    return self.acquire()
            except (OSError, ValueError):
                pass
            return False

    @classmethod
    def reclaim_if_stale(cls, root: Path, resource_id: str) -> bool:
        """Remove an orphaned lock during scheduler recovery, never a live one."""
        safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in resource_id)
        path = root / "resource-locks" / f"{safe}.lock"
        try:
            current = json.loads(path.read_text(encoding="utf-8"))
            if cls._alive(int(current.get("pid") or 0), current.get("processStartToken")):
                return False
            path.unlink(missing_ok=True)
            return True
        except FileNotFoundError:
            return False
        except (OSError, ValueError):
            return False

    @classmethod
    def reclaim_owner_locks(cls, root: Path, owner_pid: int) -> int:
        """Reclaim only monitor/task locks owned by a confirmed dead PID."""
        if owner_pid <= 0 or cls._alive(owner_pid):
            return 0
        lock_root = root / "resource-locks"
        removed = 0
        for path in lock_root.glob("*.lock"):
            try:
                current = json.loads(path.read_text(encoding="utf-8"))
                if int(current.get("pid") or 0) != owner_pid:
                    continue
                if cls._alive(owner_pid, current.get("processStartToken")):
                    continue
                path.unlink(missing_ok=True)
                removed += 1
            except (OSError, ValueError):
                continue
        return removed

    def release(self) -> None:
        if not self.held:
            return
        try:
            current = json.loads(self.path.read_text(encoding="utf-8"))
            if current.get("taskId") == self.task_id:
                self.path.unlink(missing_ok=True)
        except (OSError, ValueError):
            pass
        self.held = False
