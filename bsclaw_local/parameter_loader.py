from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any

from .scheduler_store import SchedulerDataError


def load_parameters(args: argparse.Namespace) -> dict[str, Any]:
    if getattr(args, "param_json", None):
        try:
            payload = json.loads(args.param_json)
        except json.JSONDecodeError:
            payload = _parse_cmd_safe_inline_object(args.param_json)
    elif getattr(args, "params_path", None):
        path = Path(args.params_path).resolve(strict=False)
        if path.drive.upper() != "F:":
            raise SchedulerDataError("参数文件必须位于 F 盘。")
        if not path.is_file() or path.stat().st_size > 1024 * 1024:
            raise SchedulerDataError("参数文件不存在或超过 1MB。")
        try:
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SchedulerDataError("参数文件不是有效 UTF-8 JSON。") from exc
    else:
        payload = {}
    if not isinstance(payload, dict):
        raise SchedulerDataError("任务参数根节点必须是 JSON 对象。")
    return payload


def _parse_cmd_safe_inline_object(raw: str) -> dict[str, Any]:
    text = str(raw or "").strip()
    if not (text.startswith("{") and text.endswith("}")):
        raise SchedulerDataError("--param-json 不是有效 JSON。")
    body = text[1:-1].strip()
    if not body:
        return {}
    output: dict[str, Any] = {}
    for item in body.split(","):
        if ":" not in item:
            raise SchedulerDataError("--param-json 不是有效 JSON。")
        key_text, value_text = item.split(":", 1)
        key = key_text.strip().strip("'\"")
        value = value_text.strip().strip("'\"")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*", key):
            raise SchedulerDataError("--param-json 仅支持安全的扁平对象；复杂参数请使用 --params F盘JSON文件。")
        if value in {"true", "false", "null"}:
            parsed: Any = {"true": True, "false": False, "null": None}[value]
        elif re.fullmatch(r"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?", value):
            parsed = float(value) if "." in value else int(value)
        elif re.fullmatch(r"[A-Za-z0-9_.:/@+\-]+", value):
            parsed = value
        else:
            raise SchedulerDataError("--param-json 仅支持安全的扁平对象；复杂参数请使用 --params F盘JSON文件。")
        output[key] = parsed
    return output
