from __future__ import annotations

from typing import Any

from .console_common import ConsoleIO
from .resource_console import ResourceConsole
from .service_console import ServiceConsole
from .task_console import TaskConsole
from .resource_admin_console import ResourceAdminConsole
from .monitor_console import MonitorConsole


class UserConsole:
    """Small user router; service, resource and task pages are separate."""

    def __init__(self, application: Any) -> None:
        self.app = application
        self.io = ConsoleIO()
        self.tasks = TaskConsole(application)
        self.resources = ResourceConsole(application, self.tasks)
        self.services = ServiceConsole(application, self.tasks)
        self.resource_admin = ResourceAdminConsole(application, self.tasks)
        self.monitor = MonitorConsole(application)

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
            print("6. 找一个爆款加入分销")
            print("7. 查看已接入模块（当前无业务模块时只显示状态）")
            print("\n[任务与审计]")
            print("8. 任务中心")
            print("9. 最近检查记录")
            print("10. 生成审计摘要")
            print("\n[资源维护]")
            print("11. 资源生命周期管理")
            print("12. 后台资源检测")
            pending_manual = self.tasks.pending_manual_count()
            print(f"13. 待处理人工事项{f'（{pending_manual}）' if pending_manual else ''}")
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
                self.tasks.run_hot_add_distribution()
            elif choice == "7":
                self.services.modules()
            elif choice == "8":
                self.tasks.center()
            elif choice == "9":
                self.services.recent()
            elif choice == "10":
                self.services.audit()
            elif choice == "11":
                self.resource_admin.center()
            elif choice == "12":
                self.monitor.center()
            elif choice == "13":
                self.tasks.manual_center()
            else:
                print("请输入 0 到 13。")
