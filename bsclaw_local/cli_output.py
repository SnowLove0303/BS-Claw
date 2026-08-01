from __future__ import annotations

import json
from typing import Any


def print_json(value: dict[str, Any]) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


def print_task(result: dict[str, Any]) -> None:
    print(result["message"])
    if result.get("taskId"):
        print(f"任务编号：{result['taskId']}")
    if result.get("state"):
        print(f"当前状态：{result['state']}")
    if result.get("errorCode"):
        print(f"错误码：{result['errorCode']}")
    if result.get("nextAction"):
        print(f"下一步：{result['nextAction']}")


def print_human(command: str, result: dict[str, Any]) -> None:
    print(f"\n{result['summary']}")
    if command == "status":
        print(f"总体状态：{result['overallState']}")
    data = result["data"]
    if command == "resources" and isinstance(data, list):
        for item in data:
            print(f"- {item['resourceId']} / {item['port']}：{item['state']}（{item['summary']}）")
    elif command == "huice" and isinstance(data, dict):
        for item in data.get("resources", []):
            print(f"- {item['resourceId']}：{item['state']} / 接口 {item['apiStatus']}")
    elif command == "modules" and isinstance(data, list):
        _print_modules(data)
    elif command == "diagnose" and isinstance(data, dict):
        _print_diagnostic(data)
    elif command == "audit" and isinstance(data, dict):
        print(f"结论：{data['conclusion']}")
    elif command == "tasks" and isinstance(data, list):
        if not data:
            print("暂无任务记录。")
        for item in data:
            print(f"- {item['createdAt']} / {item['action']} / {item['status']}：{item['summary']}")
    elif isinstance(data, dict) and data.get("services"):
        print(f"- 端口管理：{data['services']['portManager']['state']}")
        print(f"- 慧策资源：{data['services']['huice']['state']}")
    if command == "status" or not result["success"]:
        print(f"下一步：{result['nextAction']}")


def _print_modules(data: list[dict[str, Any]]) -> None:
    if not data:
        print("- 未发现正式服务插件或业务模块")
    names = {"service": "本地服务", "resource-service": "资源服务", "workflow": "工作流", "business-module": "业务模块"}
    for item in data:
        friendly_summary = (
            "已接入，可以查看"
            if item.get("state") == "已注册"
            else "尚未接入，当前不能执行"
        )
        print(f"- [{names.get(item.get('type'), '资料/未分类')}] {item['name']}：{item['state']}（{friendly_summary}）")


def _print_diagnostic(data: dict[str, Any]) -> None:
    for label, key in (("正常", "normal"), ("异常", "abnormal"), ("未验证", "unverified"), ("需人工处理", "manualAction")):
        print(f"{label}：")
        for value in data.get(key) or ["无"]:
            print(f"  - {value}")
    counts = data.get("resources", {}).get("counts", {})
    if counts:
        print(f"资源：可用 {counts.get('ready', 0)}，未验证 {counts.get('unverified', 0)}，需登录 {counts.get('loginRequired', 0)}，需修复/不可用 {counts.get('repairRequired', 0) + counts.get('unavailable', 0)}")
