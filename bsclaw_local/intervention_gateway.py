from __future__ import annotations

import json
import importlib.util
import secrets
import socket
import socketserver
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any


@dataclass
class InterventionResult:
    action: str
    values: dict[str, str]


class _Handler(socketserver.StreamRequestHandler):
    def handle(self) -> None:  # pragma: no cover - exercised by the real window
        gateway: InterventionGateway = self.server.gateway
        try:
            payload = json.loads(self.rfile.readline().decode("utf-8"))
            if payload.get("nonce") != gateway.nonce:
                return
            action = str(payload.get("action") or "cancel").strip().lower()
            if gateway.context.get("mode") == "login":
                if action != "submit":
                    action = "cancel"
                raw_values = payload.get("values")
                values = gateway._sanitize_login_values(raw_values)
            else:
                action = action if action in {"continue", "cancel"} else "cancel"
                values = {}
            gateway.result = InterventionResult(
                action=action,
                values=values,
            )
            gateway.event.set()
        except (OSError, ValueError, TypeError):
            gateway.result = InterventionResult("cancel", {})
            gateway.event.set()


class InterventionGateway:
    """One-shot, localhost-only IPC bridge for the visible intervention window."""

    def __init__(self) -> None:
        self.nonce = secrets.token_urlsafe(24)
        self.event = threading.Event()
        self.result: InterventionResult | None = None
        self.context: dict[str, str] = {}
        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), _Handler)
        self.server.daemon_threads = True
        self.server.gateway = self
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def _sanitize_login_values(self, values: object) -> dict[str, str]:
        if not isinstance(values, dict):
            return {}
        allowed = ("tenant", "account", "password")
        sanitized: dict[str, str] = {}
        for key in allowed:
            value = values.get(key)
            if isinstance(value, str):
                sanitized[key] = value[:512]
        return sanitized

    def open(self, context: dict[str, str], timeout_seconds: int = 900) -> InterventionResult:
        self.context = {
            key: str(value)
            for key, value in context.items()
            if key in {"mode", "taskName", "resource", "reason", "localRoot"}
        }
        self.thread.start()
        use_tkinter = importlib.util.find_spec("tkinter") is not None
        if use_tkinter:
            args = [sys.executable, "-m", "bsclaw_local.intervention_window"]
            parameter_prefix = "--"
        else:
            args = [
                "powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass",
                "-File", str(context["windowScript"]),
            ]
            parameter_prefix = "-"
        args.extend([f"{parameter_prefix}port", str(self.server.server_address[1]), f"{parameter_prefix}nonce", self.nonce])
        for key in ("taskName", "resource", "reason", "mode", "localRoot"):
            value = context.get(key)
            if value is not None:
                args.extend([f"{parameter_prefix}{key}", value])
        creationflags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        process: subprocess.Popen[bytes] | None = None
        try:
            process = subprocess.Popen(
                args,
                cwd=str(context["localRoot"]),
                creationflags=creationflags,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            deadline = time.monotonic() + max(1, timeout_seconds)
            while self.result is None and time.monotonic() < deadline:
                if self.event.wait(0.2):
                    break
                if process.poll() is not None:
                    self.result = InterventionResult("window-exited", {})
                    break
            if self.result is None:
                self.result = InterventionResult("timeout", {})
        finally:
            if process is not None and process.poll() is None:
                try:
                    process.terminate()
                except OSError:
                    pass
            if process is not None:
                try:
                    process.wait(timeout=3)
                except OSError:
                    pass
                except subprocess.TimeoutExpired:
                    try:
                        process.kill()
                    except OSError:
                        pass
        self.server.shutdown()
        self.server.server_close()
        return self.result
