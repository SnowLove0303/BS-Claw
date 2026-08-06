from __future__ import annotations

from typing import Any

from .console_common import ConsoleIO
from .resource_selector import ResourceSelector


class ResourceAdminConsole:
    """User-facing resource lifecycle. All mutations go through public PM actions."""

    def __init__(self, application: Any, tasks: Any) -> None:
        self.app = application
        self.tasks = tasks
        self.io = ConsoleIO()

    def center(self) -> None:
        while True:
            print("\n资源管理")
            print("1. 注册新资源")
            print("2. 编辑资源")
            print("3. 启用资源")
            print("4. 停用资源")
            print("5. 删除资源")
            print("6. 检查全部资源")
            print("7. 查看占用情况")
            print("8. 启动登录状态检查")
            print("0. 返回")
            choice = self.io.input("请选择").strip()
            if choice == "0":
                return
            if choice == "1":
                self.register()
            elif choice in {"2", "3", "4", "5", "7", "8"}:
                self._resource_action(choice)
            elif choice == "6":
                capability = self.tasks.capability("port-manager", "check-all")
                self.tasks.run_capability(capability, timeout_seconds=180)
                self.app.port_manager.invalidate_cache()
            else:
                print("请输入 0 到 8。")

    def register(self) -> None:
        name = self.io.input("资源名称").strip()
        host = self.io.input("主机地址（直接回车使用 127.0.0.1）", allow_empty=True).strip() or "127.0.0.1"
        port = self.io.input("端口号").strip()
        mode = self.io.input("连接方式（1=连接已打开浏览器，2=需要时启动浏览器）").strip()
        if not name or not port.isdigit() or mode not in {"1", "2"}:
            print("注册信息不完整；资源没有改变。")
            return
        args = {"resourceName": name, "hostName": host, "port": int(port), "connectionMode": "Launch" if mode == "2" else "ConnectOnly"}
        capability = self.tasks.capability("port-manager", "register")
        self.tasks.run_capability(capability, timeout_seconds=90, parameters=args)

    def _resource_action(self, choice: str) -> None:
        resource = ResourceSelector(self.app, self.io).select("single")
        if resource is None:
            print("资源序号无效。")
            return
        rid = str(resource.get("resourceId") or "")
        label = f"{resource.get('name') or resource.get('resourceName') or '未命名资源'}（端口 {resource.get('port') or '未知'}）"
        if choice == "2":
            name = self.io.input(f"新名称（直接回车保持 {resource.get('name') or resource.get('resourceName')}）", allow_empty=True).strip()
            capability = self.tasks.capability("port-manager", "edit")
            self.tasks.run_capability(capability, resource_id=rid, parameters={"resourceName": name} if name else {})
            return
        elif choice == "3":
            capability = self.tasks.capability("port-manager", "enable")
        elif choice == "4":
            capability = self.tasks.capability("port-manager", "disable")
        elif choice == "5":
            if not bool(resource.get("enabled", True)):
                if not self.io.confirm(f"{label}当前已停用，删除前需要先启用。是否现在启用并继续删除？"):
                    print("已取消，资源保持停用状态，没有删除。")
                    return
                enable = self.tasks.capability("port-manager", "enable")
                enabled_task = self.tasks.run_capability(enable, resource_id=rid, skip_confirmation=True)
                if not enabled_task or enabled_task.get("state") != "成功":
                    print("资源重新启用失败，未执行删除；请先检查资源状态后重试。")
                    return
                self.app.port_manager.invalidate_cache()
            if not self.io.confirm(f"确定删除“{label}”吗？此操作不可恢复"):
                print("已取消，资源没有改变。")
                return
            capability = self.tasks.capability("port-manager", "delete")
            self.tasks.run_capability(capability, resource_id=rid, parameters={"confirmationText": "confirm-delete-selected-resource"}, skip_confirmation=True)
            return
        elif choice == "7":
            capability = self.tasks.capability("port-manager", "occupancy")
        else:
            capability = self.tasks.capability("port-manager", "login-check")
        self.tasks.run_capability(capability, resource_id=rid, timeout_seconds=90)
        self.app.port_manager.invalidate_cache()
