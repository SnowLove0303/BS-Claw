from __future__ import annotations

import json
import locale
import os
import subprocess
from pathlib import Path
from typing import Any

from .models import CommandResult


CREATE_NO_WINDOW = 0x08000000


def _decode_output(value: bytes) -> str:
    for encoding in ("utf-8-sig", locale.getpreferredencoding(False), "gb18030"):
        try:
            return value.decode(encoding)
        except (UnicodeDecodeError, LookupError):
            continue
    return value.decode("utf-8", errors="replace")


def _safe_error(message: str) -> str:
    lowered = message.lower()
    if any(token in lowered for token in ("token", "cookie", "authorization", "password")):
        return "底层返回包含受保护信息，已停止展示；请运行脱敏诊断。"
    return message.strip()[:300]


def run_powershell_json(
    script: Path,
    arguments: list[str],
    *,
    timeout_seconds: int = 45,
) -> CommandResult:
    if not script.is_file():
        return CommandResult(False, None, "正式入口文件不存在。", "ENTRY_NOT_FOUND")
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        *arguments,
    ]
    environment = os.environ.copy()
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        completed = subprocess.run(
            command,
            cwd=str(script.parent),
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_seconds,
            check=False,
            shell=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except subprocess.TimeoutExpired:
        return CommandResult(False, None, "状态读取超时。", "COMMAND_TIMEOUT")
    except OSError:
        return CommandResult(False, None, "无法启动 PowerShell 状态入口。", "POWERSHELL_UNAVAILABLE")

    stdout = _decode_output(completed.stdout).strip()
    stderr = _decode_output(completed.stderr).strip()
    try:
        payload: dict[str, Any] = json.loads(stdout)
    except (json.JSONDecodeError, TypeError):
        message = _safe_error(stderr or stdout or "正式入口没有返回有效 JSON。")
        return CommandResult(False, None, message, "INVALID_JSON_OUTPUT")

    success = bool(payload.get("success")) and completed.returncode == 0
    message = str(payload.get("message") or payload.get("summary") or "")
    error_code = str(payload.get("errorCode") or "")
    if not success and not message:
        message = _safe_error(stderr or "状态读取失败。")
    return CommandResult(success, payload.get("data"), message, error_code)


def run_powershell_interactive(script: Path, arguments: list[str]) -> int:
    if not script.is_file():
        print("端口管理入口不存在。")
        return 2
    try:
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                *arguments,
            ],
            cwd=str(script.parent),
            check=False,
            shell=False,
        )
        return completed.returncode
    except OSError:
        print("无法启动端口管理。")
        return 2
