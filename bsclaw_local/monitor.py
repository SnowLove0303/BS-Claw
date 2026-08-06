from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import now_iso
from .paths import ProjectPaths
from .resource_mutex import ResourceMutex


class ResourceMonitor:
    """Owns only the local monitor process/state; PortManager remains external."""

    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths
        self.root = paths.data_root / "monitor"
        self.state_path = self.root / "state.json"
        self.stop_path = self.root / "stop.request"

    def _read(self) -> dict[str, Any]:
        try:
            value = json.loads(self.state_path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else {}
        except (OSError, ValueError):
            return {}

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        if not pid:
            return False
        try:
            output = subprocess.run(["tasklist", "/FI", f"PID eq {pid}"], capture_output=True, timeout=3, creationflags=0x08000000)
            return str(pid).encode() in (output.stdout or b"")
        except (OSError, subprocess.TimeoutExpired):
            return False

    def status(self) -> dict[str, Any]:
        state = self._read()
        pid = int(state.get("pid") or 0)
        alive = False
        if pid:
            alive = self._pid_alive(pid)
            if not alive:
                ResourceMutex.reclaim_owner_locks(self.paths.data_root / "scheduler", pid)
        heartbeat = state.get("heartbeatAt")
        stale = True
        if heartbeat:
            try:
                stamp = datetime.fromisoformat(str(heartbeat).replace("Z", "+00:00"))
                stale = (datetime.now(timezone.utc) - stamp.astimezone(timezone.utc)).total_seconds() > 45
            except ValueError:
                stale = True
        previous_status = str(state.get("status") or "")
        state.update({"alive": alive, "stale": stale, "status": "running" if alive and not stale else "stopped-or-stale"})
        intentional_stop = self.stop_path.exists()
        if not alive and previous_status == "stopped":
            state.update({"status": "stopped", "stale": False})
        elif not alive and previous_status == "failed" and state.get("errorCode"):
            state.update({"status": "failed"})
        elif not alive and previous_status == "stopped-or-stale" and state.get("errorCode") == "MONITOR_PROCESS_EXITED_BEFORE_HEARTBEAT":
            state.update({"status": "failed"})
        elif not alive and previous_status in {"starting", "running"} and not intentional_stop:
            if state.get("errorCode"):
                state.update({"status": "failed"})
            else:
                state.update({"status": "failed", "errorCode": "MONITOR_PROCESS_EXITED_BEFORE_HEARTBEAT", "nextAction": "查看 F 盘监控诊断后重新启动后台检测"})
        elif alive and not state.get("heartbeatAt"):
            state.update({"status": "running", "phase": "initial-scan", "nextAction": "等待首轮资源检查完成"})
        elif alive and stale:
            state.update({"status": "stale", "errorCode": "MONITOR_HEARTBEAT_EXPIRED", "nextAction": "选择启动或恢复后台检测"})
        elif not alive and state.get("heartbeatAt") and state.get("lastCycleAt"):
            state.pop("errorCode", None)
            state.pop("nextAction", None)
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            self.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        except OSError:
            pass
        return state

    def start(self) -> dict[str, Any]:
        current = self.status()
        if current.get("alive") and not current.get("stale"):
            return current
        if current.get("alive") and current.get("stale"):
            old_pid = int(current.get("pid") or 0)
            if old_pid:
                subprocess.run(["taskkill", "/PID", str(old_pid), "/T", "/F"], capture_output=True, check=False)
        self.root.mkdir(parents=True, exist_ok=True)
        self.stop_path.unlink(missing_ok=True)
        # The bundled Python uses an isolated ``._pth`` configuration and
        # ignores PYTHONPATH.  Inject the verified F-drive project root in a
        # tiny command shim so ``bsclaw_local`` is importable from the formal
        # PowerShell launcher as well as from a direct Python invocation.
        project_literal = repr(str(self.paths.local_root))
        command_code = (
            f"import sys; sys.path.insert(0, {project_literal}); "
            f"from bsclaw_local.monitor import run_worker; "
            f"raise SystemExit(run_worker({project_literal}))"
        )
        command = [sys.executable, "-B", "-c", command_code]
        diagnostics = self.root / "diagnostics"
        diagnostics.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        stdout_path = diagnostics / f"monitor-{stamp}.stdout.log"
        stderr_path = diagnostics / f"monitor-{stamp}.stderr.log"
        stdout_file = stdout_path.open("ab")
        stderr_file = stderr_path.open("ab")
        environment = os.environ.copy()
        # The bundled F-drive Python does not necessarily retain the caller's
        # import path when launched from a .cmd wrapper.  Pin the local package
        # root explicitly so the worker cannot die before its first heartbeat.
        existing_python_path = environment.get("PYTHONPATH", "")
        environment["PYTHONPATH"] = (
            str(self.paths.local_root)
            + (os.pathsep + existing_python_path if existing_python_path else "")
        )
        environment["BSCLAW_DATA_ROOT"] = str(self.paths.data_root)
        environment["BSCLAW_PORT_MANAGER_ROOT"] = str(self.paths.port_manager_root)
        environment["BSCLAW_HUICE_LOGIN_AGENT_ROOT"] = str(self.paths.huice_login_agent_root)
        try:
            process = subprocess.Popen(
                command,
                cwd=str(self.paths.local_root),
                stdout=stdout_file,
                stderr=stderr_file,
                stdin=subprocess.DEVNULL,
                creationflags=0x08000000,
                env=environment,
            )
        except OSError:
            stdout_file.close()
            stderr_file.close()
            raise
        stdout_file.close()
        stderr_file.close()
        # The worker can write its first heartbeat before Popen returns. Merge
        # rather than replacing the state file so the parent cannot erase that
        # evidence and leave the UI stuck at an empty initial-scan snapshot.
        state = self._read()
        state.update({
            "pid": process.pid,
            "startedAt": state.get("startedAt") or now_iso(),
            "status": state.get("status") or "starting",
            "resources": state.get("resources") or {},
            "pythonPath": sys.executable,
            "command": ["-B", "-c", "<local-monitor-worker-shim>"],
            "workingDirectory": str(self.paths.local_root),
            "stdoutPath": str(stdout_path),
            "stderrPath": str(stderr_path),
        })
        self.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
        return self.status()

    def stop(self) -> dict[str, Any]:
        self.root.mkdir(parents=True, exist_ok=True)
        self.stop_path.write_text(now_iso(), encoding="utf-8")
        state = self.status()
        pid = int(state.get("pid") or 0)
        if pid and state.get("alive"):
            for _ in range(20):
                time.sleep(0.15)
                if not self.status().get("alive"):
                    break
            if self.status().get("alive"):
                # Only terminate the monitor process owned by this state file;
                # never touch Chrome or PortManager processes.
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError:
                    pass
                if self.status().get("alive"):
                    subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True, check=False)
        final = self.status()
        if not final.get("alive"):
            final.update({"status": "stopped", "stale": False})
            final.pop("errorCode", None)
            final.pop("nextAction", None)
            try:
                self.state_path.write_text(json.dumps(final, ensure_ascii=False, indent=2), encoding="utf-8")
            except OSError:
                pass
        return final


def run_worker(local_root: str) -> int:
    from .paths import ProjectPaths
    from .port_manager import PortManagerAdapter

    paths = ProjectPaths.discover()
    monitor = ResourceMonitor(paths)
    monitor.root.mkdir(parents=True, exist_ok=True)
    state = monitor._read()
    state["pid"] = os.getpid()
    state["status"] = "running"
    state["alive"] = True
    state["stale"] = False
    state["phase"] = "initial-scan"
    state["heartbeatAt"] = now_iso()
    state_lock = threading.Lock()
    stop_heartbeat = threading.Event()

    def write_state(changes: dict[str, Any]) -> None:
        nonlocal state
        with state_lock:
            state.update(changes)
            monitor.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")

    write_state({})

    def heartbeat_loop() -> None:
        while not stop_heartbeat.wait(5):
            # Keep heartbeat fresh during a slow PortManager cycle.  The
            # heartbeat proves only that this worker is alive; resource facts
            # are updated separately when each check completes.
            write_state({"status": "running", "alive": True, "stale": False, "heartbeatAt": now_iso()})

    heartbeat_thread = threading.Thread(target=heartbeat_loop, name="bsclaw-monitor-heartbeat", daemon=True)
    heartbeat_thread.start()
    while not monitor.stop_path.exists():
        result = PortManagerAdapter(paths).list_resources(force_refresh=True)
        resources: dict[str, Any] = {}
        if result.success:
            enabled = [item for item in (result.data or []) if item.get("enabled", True) and item.get("resourceId")]
            def check_one(item: dict[str, Any]) -> tuple[str, dict[str, Any]]:
                rid = str(item["resourceId"])
                mutex = ResourceMutex(paths.data_root / "scheduler", rid, f"MONITOR-{os.getpid()}")
                if not mutex.acquire():
                    return rid, {"state": item.get("state") or "检测中", "freshness": "等待其他检查完成", "checkedAt": now_iso(), "summary": "该资源正由其他检查占用，下一轮自动重试", "success": False, "errorCode": "RESOURCE_BUSY"}
                try:
                    checked = PortManagerAdapter(paths).check_resource(rid)
                    value = checked.data if isinstance(checked.data, dict) else {}
                    safe = PortManagerAdapter.sanitize_checked(value, base_resource=item) if isinstance(value, dict) else dict(item)
                    safe["success"] = checked.success
                    safe["summary"] = checked.message or safe.get("summary") or item.get("summary")
                    safe["checkedAt"] = safe.get("checkedAt") or now_iso()
                    if not checked.success:
                        safe["freshness"] = "检测失败"
                    return rid, safe
                finally:
                    mutex.release()
            with ThreadPoolExecutor(max_workers=max(1, min(4, len(enabled)))) as pool:
                futures = {pool.submit(check_one, item): str(item["resourceId"]) for item in enabled}
                for future in as_completed(futures):
                    rid = futures[future]
                    try:
                        _, value = future.result()
                    except Exception as exc:
                        value = {"state": "需修复", "freshness": "检测失败", "checkedAt": now_iso(), "summary": "该资源检测异常，其他资源仍继续检查", "success": False, "errorCode": type(exc).__name__}
                    resources[rid] = value
        write_state({"status": "running", "alive": True, "stale": False, "heartbeatAt": now_iso(), "lastCycleAt": now_iso(), "phase": "sleeping", "resources": resources, "lastError": None if result.success else result.message})
        with state_lock:
            state.pop("errorCode", None)
            state.pop("nextAction", None)
        time.sleep(20)
    stop_heartbeat.set()
    heartbeat_thread.join(timeout=2)
    write_state({"status": "stopped", "alive": False, "stale": False, "heartbeatAt": now_iso(), "phase": "stopped"})
    with state_lock:
        state.pop("errorCode", None)
        state.pop("nextAction", None)
        monitor.state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")
    monitor.stop_path.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(run_worker(sys.argv[1] if len(sys.argv) > 1 else ""))
