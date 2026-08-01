from __future__ import annotations

from typing import Any

from .console_common import ConsoleIO
from .resource_console import ResourceConsole
from .service_console import ServiceConsole
from .task_console import TaskConsole


class UserConsole:
    """Small user router; service, resource and task pages are separate."""

    def __init__(self, application: Any) -> None:
        self.app = application
        self.io = ConsoleIO()
        self.tasks = TaskConsole(application)
        self.resources = ResourceConsole(application, self.tasks)
        self.services = ServiceConsole(application, self.tasks)

    def run(self) -> int:
        while True:
            print("\nBS Claw")
            print("请选择要完成的操作")
            print("\n[本地服务]")
            print("1. 本地服务总览")
            print("2. 端口资源")
            print("3. 慧策资源与登录状态")
            print("4. 服务诊断")
            print("5. 打开原端口管理")
            print("\n[执行模块]")
            print("6. 查看已接入模块（当前无业务模块时只显示状态）")
            print("\n[任务与审计]")
            print("7. 任务中心")
            print("8. 最近检查记录")
            print("9. 生成审计摘要")
            print("0. 退出")
            choice = self.io.input("请选择").lower()
            if choice == "0":
                print("已退出 BS Claw。")
                return 0
            if choice == "1":
                self.services.overview()
            elif choice == "2":
                self.resources.center()
            elif choice == "3":
                self.resources.login_gate()
            elif choice == "4":
                self.services.diagnostic()
            elif choice == "5":
                print("正在打开原端口管理；退出后会返回这里。")
                self.app.port_manager.open_menu()
            elif choice == "6":
                self.services.modules()
            elif choice == "7":
                self.tasks.center()
            elif choice == "8":
                self.services.recent()
            elif choice == "9":
                self.services.audit()
            else:
                print("请输入 0 到 9。")
