from __future__ import annotations

from typing import Any


STATE_HINTS = {
    "可用": "可以继续使用",
    "需登录": "请使用正式登录入口完成登录",
    "未验证": "请先重新检查状态",
    "需修复": "请先处理状态维护异常",
    "不可用": "当前不能使用",
}


class ConsoleIO:
    @staticmethod
    def input(prompt: str, *, allow_empty: bool = False) -> str:
        try:
            value = input(f"{prompt}: ").strip()
        except EOFError:
            return "" if allow_empty else "0"
        return value

    @staticmethod
    def confirm(message: str) -> bool:
        try:
            return input(f"{message} 请输入“确认”继续: ").strip() == "确认"
        except EOFError:
            return False

    @staticmethod
    def failure(message: str, error_code: str, next_action: str) -> None:
        print(f"操作失败：{message or '未获得有效结果'}")
        if error_code:
            print(f"错误类型：{error_code}")
        print(f"下一步：{next_action}")

    @staticmethod
    def selected(items: list[dict[str, Any]], value: str) -> dict[str, Any] | None:
        try:
            index = int(value) - 1
        except ValueError:
            return None
        return items[index] if 0 <= index < len(items) else None

    @staticmethod
    def short_time(value: Any) -> str:
        text = str(value or "")
        return text.replace("T", " ")[:19] if text else "时间未知"

    @staticmethod
    def format_bytes(value: int) -> str:
        number = float(max(0, value))
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if number < 1024 or unit == "TB":
                return f"{number:.1f} {unit}"
            number /= 1024
        return f"{number:.1f} TB"

    @staticmethod
    def friendly_next_action(task: dict[str, Any]) -> str:
        if task.get("state") == "成功":
            return "操作已完成，可返回继续使用"
        error_code = str(task.get("errorCode") or "")
        if error_code == "ACTION_NOT_SUPPORTED":
            return "此请求不是菜单支持的操作，不影响菜单中的正常功能。"
        if error_code == "MODULE_NOT_FOUND":
            return "当前没有接入对应模块；可返回菜单继续使用其他功能。"
        if error_code in {"MODULE_MANIFEST_INVALID", "MODULE_ENTRY_NOT_FOUND"}:
            return "该模块尚未完成接入；可返回菜单继续使用其他功能。"
        text = str(task.get("nextAction") or "")
        for source, target in {
            "task result": "任务详情",
            "task status": "任务中心",
            "ResourceId": "资源编号",
        }.items():
            text = text.replace(source, target)
        return text or "根据结果提示处理后重试"


def resource_counts(resources: list[dict[str, Any]]) -> dict[str, int]:
    counts = {"可用": 0, "需登录": 0, "未验证": 0, "异常": 0}
    for item in resources:
        state = str(item.get("state") or "未验证")
        if state in counts and state != "异常":
            counts[state] += 1
        else:
            counts["异常"] += 1
    return counts
