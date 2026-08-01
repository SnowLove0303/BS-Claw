from __future__ import annotations

import json
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from .module_registry import RegisteredModule
from .scheduler_store import redact_structure, sanitize_text


CREATE_NO_WINDOW = 0x08000000


@dataclass(frozen=True)
class PluginExecution:
    success: bool
    payload: dict[str, Any] | None
    error_code: str
    message: str
    timed_out: bool = False
    cancelled: bool = False


def execute_plugin(
    module: RegisteredModule,
    payload: dict[str, Any],
    *,
    timeout_seconds: int,
    cancel_requested: Callable[[], bool] | None = None,
) -> PluginExecution:
    entry = module.manifest["entry"]
    entry_path = (module.root / str(entry["path"])).resolve(strict=False)
    runtime = str(entry["runtime"])
    if runtime == "python":
        command = [sys.executable, "-B", str(entry_path)]
    elif runtime == "powershell":
        command = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(entry_path),
        ]
    else:
        return PluginExecution(False, None, "PLUGIN_RUNTIME_UNSUPPORTED", "插件运行时不受支持")
    try:
        process = subprocess.Popen(
            command,
            cwd=str(module.root),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            shell=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except OSError:
        return PluginExecution(False, None, "PLUGIN_START_FAILED", "无法启动插件进程")
    stdout_chunks: list[bytes] = []
    stderr_chunks: list[bytes] = []

    def read_stream(stream: Any, destination: list[bytes]) -> None:
        if stream is not None:
            destination.append(stream.read())

    stdout_reader = threading.Thread(
        target=read_stream,
        args=(process.stdout, stdout_chunks),
        daemon=True,
    )
    stderr_reader = threading.Thread(
        target=read_stream,
        args=(process.stderr, stderr_chunks),
        daemon=True,
    )
    stdout_reader.start()
    stderr_reader.start()
    try:
        assert process.stdin is not None
        process.stdin.write(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        process.stdin.close()
    except (BrokenPipeError, OSError):
        _stop_process(process)
        return PluginExecution(False, None, "PLUGIN_INPUT_FAILED", "无法向插件传入统一任务")
    deadline = time.monotonic() + timeout_seconds
    cancelled = False
    timed_out = False
    while process.poll() is None:
        if cancel_requested is not None and cancel_requested():
            cancelled = True
            _stop_process(process)
            break
        if time.monotonic() >= deadline:
            timed_out = True
            _stop_process(process)
            break
        time.sleep(0.1)
    stdout_reader.join(timeout=2)
    stderr_reader.join(timeout=2)
    if cancelled:
        return PluginExecution(
            False,
            None,
            "TASK_CANCELLED",
            "任务已取消，插件进程已停止",
            cancelled=True,
        )
    if timed_out:
        return PluginExecution(
            False,
            None,
            "PLUGIN_TIMEOUT",
            "插件执行超时，进程已停止",
            timed_out=True,
        )
    stdout = b"".join(stdout_chunks)
    try:
        output = json.loads(stdout.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return PluginExecution(
            False,
            None,
            "PLUGIN_INVALID_JSON",
            "插件没有返回单一有效 JSON",
        )
    if not isinstance(output, dict):
        return PluginExecution(False, None, "PLUGIN_INVALID_RESULT", "插件结果必须是 JSON 对象")
    required = {
        "success",
        "status",
        "result",
        "errorCode",
        "message",
        "needsManualAction",
        "evidence",
        "businessWritesExecuted",
        "serviceStateWritesExecuted",
    }
    if not required.issubset(output):
        return PluginExecution(
            False,
            None,
            "PLUGIN_CONTRACT_INCOMPLETE",
            "插件结果缺少统一协议字段",
        )
    safe_output = {
        "success": bool(output.get("success")),
        "status": sanitize_text(output.get("status"), 80),
        "result": redact_structure(output.get("result")),
        "errorCode": sanitize_text(output.get("errorCode"), 80) or None,
        "message": sanitize_text(output.get("message")),
        "needsManualAction": bool(output.get("needsManualAction")),
        "evidence": redact_structure(output.get("evidence")),
        "businessWritesExecuted": bool(output.get("businessWritesExecuted")),
        "serviceStateWritesExecuted": bool(
            output.get("serviceStateWritesExecuted")
        ),
    }
    return PluginExecution(
        process.returncode == 0 and safe_output["success"],
        safe_output,
        str(safe_output["errorCode"] or ""),
        str(safe_output["message"] or ""),
    )


def _stop_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)
