from __future__ import annotations

import os
import shutil
from pathlib import Path
from typing import Any

from .capabilities import BUSINESS_TYPES, SERVICE_TYPES
from .console_common import ConsoleIO, resource_counts
from .task_console import TaskConsole


class ServiceConsole:
    def __init__(self, application: Any, tasks: TaskConsole) -> None:
        self.app = application
        self.tasks = tasks
        self.io = ConsoleIO()

    def overview(self) -> None:
        snapshot, modules = self.app.snapshot()
        resources = snapshot.get("huice", {}).get("resources") or []
        counts = resource_counts(resources)
        services = [item for item in modules if item.get("type") in SERVICE_TYPES]
        business = [item for item in modules if item.get("type") in BUSINESS_TYPES]
        print("\n本地服务总览")
        print(f"- 端口管理：{snapshot['portManager']['state']}")
        print(
            "- 慧策资源："
            f"可用 {counts['可用']}，需登录 {counts['需登录']}，"
            f"未验证 {counts['未验证']}，异常 {counts['异常']}"
        )
        print(f"- 本地服务插件：{'已接入' if services else '未接入'}")
        print(f"- 业务执行模块：{'已接入' if business else '暂无可用业务模块'}")
        timing = snapshot.get("portManager", {}).get("timingMs")
        if timing is not None:
            print(f"- 状态读取：{'复用本地缓存' if timing == 0 else f'真实读取 {timing} ms'}")
        stale = sum(1 for item in resources if item.get("freshness") == "已过期")
        never = sum(1 for item in resources if item.get("freshness") == "从未检测")
        if stale or never:
            print(f"- 状态新鲜度：已过期 {stale}，从未检测 {never}；不会把旧记录当作当前可用")
        warning = self._launcher_warning()
        if warning:
            print(f"- 启动入口：{warning}")
        print(f"下一步：{self._overview_next_action(counts, snapshot)}")
        print("1. 运行完整服务检查   0. 返回")
        if self.io.input("请选择").lower() == "1":
            self.tasks.run_capability(
                self.tasks.capability("port-manager", "service-check"),
                timeout_seconds=90,
            )

    def modules(self) -> None:
        result = self.app.execute("modules", no_record=False)
        items = result.get("data") if isinstance(result.get("data"), list) else []
        services = [item for item in items if item.get("type") in SERVICE_TYPES]
        business = [item for item in items if item.get("type") in BUSINESS_TYPES]
        print("\n本地服务")
        if not services:
            print("- 暂无已接入服务")
        for item in services:
            print(f"- {item.get('name')}：{item.get('state')}")
        print("\n执行模块")
        if not business:
            print("- 暂无可用业务模块；不会显示或执行假业务入口。")
        for item in business:
            print(f"- {item.get('name')}：{item.get('state')}")
        print("当前没有可执行的业务模块；接入完成后会在这里显示。")

    def diagnostic(self) -> None:
        result = self.app.execute("diagnose", no_record=False)
        print(f"\n诊断结果：{result.get('summary')}")
        data = result.get("data") if isinstance(result.get("data"), dict) else {}
        for label, key in (
            ("正常", "normal"),
            ("异常", "abnormal"),
            ("未验证", "unverified"),
            ("需要人工处理", "manualAction"),
        ):
            values = data.get(key) or []
            print(f"{label}：{len(values)} 项")
            for value in values:
                print(f"- {value}")
        print(f"下一步：{result.get('nextAction')}")

    def audit(self) -> None:
        targets = ("本地服务整体", "端口管理", "慧策资源")
        audit_types = ("状态审计", "真实路径审计", "接口只读审计", "模块可用性审计")
        print("\n生成审计摘要")
        for index, target in enumerate(targets, 1):
            print(f"{index}. {target}")
        print("0. 返回")
        choice = self.io.input("请选择检查对象")
        if choice == "0":
            return
        try:
            target = targets[int(choice) - 1]
        except (ValueError, IndexError):
            print("检查对象无效。")
            return
        for index, audit_type in enumerate(audit_types, 1):
            print(f"{index}. {audit_type}")
        try:
            audit_type = audit_types[int(self.io.input("请选择")) - 1]
        except (ValueError, IndexError):
            print("检查方式无效。")
            return
        result = self.app.execute(
            "audit", target=target, audit_type=audit_type, no_record=False
        )
        data = result.get("data") if isinstance(result.get("data"), dict) else {}
        print(f"结论：{data.get('conclusion') or result.get('overallState') or '未验证'}")
        print(f"说明：{result.get('summary')}")
        print(f"下一步：{result.get('nextAction')}")

    def recent(self) -> None:
        records = self.app.tasks.recent(20)
        print("\n最近检查记录")
        if not records:
            print("暂无检查记录。")
            return
        friendly = {
            "status": "本地服务总览",
            "resources": "资源列表检查",
            "huice": "登录状态检查",
            "modules": "模块与服务检查",
            "diagnose": "系统诊断",
            "audit": "审计摘要",
            "resource-check": "资源状态检查",
            "open-resource": "打开资源",
            "resource-login": "正式登录",
        }
        for item in records:
            name = friendly.get(str(item.get("action") or ""), "本地检查")
            print(
                f"- {name}：{item.get('status') or '未验证'} / "
                f"{self.io.short_time(item.get('createdAt'))}"
            )
            print(f"  {item.get('summary') or '暂无结果摘要'}")

    def _launcher_warning(self) -> str:
        expected = self.app.paths.local_root / "tools" / "command-launcher" / "bsclaw.cmd"
        compatibility = (
            self.app.paths.local_root.parent
            / "PortManager-Phase1"
            / "tools"
            / "command-launcher"
            / "bsclaw.cmd"
        )
        resolved = shutil.which("bsclaw")
        if not resolved:
            return "当前会话找不到快捷入口；请运行本地层安装脚本后重开 PowerShell"
        try:
            resolved_path = os.path.normcase(str(Path(resolved).resolve()))
            expected_path = os.path.normcase(str(expected.resolve()))
            compatibility_path = os.path.normcase(str(compatibility.resolve()))
        except OSError:
            return "当前快捷入口无法确认；请运行本地层安装脚本后重开 PowerShell"
        if resolved_path == expected_path:
            return "正常"
        if resolved_path == compatibility_path:
            return "当前从兼容入口启动；请运行本地层安装脚本后重开 PowerShell"
        return "当前命令不是 BS Claw 正式入口；请运行本地层安装脚本后重开 PowerShell"

    @staticmethod
    def _overview_next_action(counts: dict[str, int], snapshot: dict[str, Any]) -> str:
        if snapshot.get("portManager", {}).get("state") != "可用":
            return "先检查本地服务"
        if counts["需登录"]:
            return "进入“慧策资源与登录状态”处理需登录资源"
        if counts["未验证"]:
            return "进入“端口资源”选择资源并重新检查"
        return "本地资源状态已就绪"
