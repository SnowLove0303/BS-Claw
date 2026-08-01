from __future__ import annotations

from typing import Any

from .console_common import ConsoleIO, STATE_HINTS, resource_counts
from .task_console import TaskConsole


class ResourceConsole:
    """PortManager user pages; all service calls stay behind public adapters."""

    def __init__(self, application: Any, tasks: TaskConsole) -> None:
        self.app = application
        self.tasks = tasks
        self.io = ConsoleIO()

    def center(self) -> None:
        while True:
            result = self.app.port_manager.list_resources()
            if not result.success:
                self.io.failure(result.message, result.error_code, "检查端口管理入口后刷新")
                return
            resources = result.data if isinstance(result.data, list) else []
            print("\n端口资源")
            if not resources:
                print("当前没有登记的端口资源。")
                print("下一步：进入端口管理登记资源。")
                return
            self._print_list(resources)
            print("R. 刷新   0. 返回")
            choice = self.io.input("请选择资源序号").lower()
            if choice == "0":
                return
            if choice == "r":
                continue
            resource = self.io.selected(resources, choice)
            if resource is None:
                print("请选择列表中的有效序号。")
                continue
            self.detail(resource)

    def detail(self, resource: dict[str, Any]) -> None:
        resource_id = str(resource.get("resourceId") or "")
        detail = self.tasks.run_capability(
            self.tasks.capability("port-manager", "resource-detail"),
            resource_id=resource_id,
            quiet_result=True,
        )
        resource = self._resource_from_task(resource, detail)
        while True:
            resource_id = str(resource.get("resourceId") or resource_id)
            self._print_detail(resource)
            print("1. 重新检查状态（会更新服务运行状态）")
            print("2. 打开或复用资源（会操作 Chrome，需确认）")
            print("3. 查看存储与缓存情况（只做盘点，不删除）")
            print("4. 进入正式登录（仅在需登录时使用，需确认）")
            print("0. 返回资源列表")
            choice = self.io.input("请选择").lower()
            if choice == "0":
                return
            if choice == "1":
                task = self.tasks.run_capability(
                    self.tasks.capability("port-manager", "check-resource"),
                    resource_id=resource_id,
                    timeout_seconds=90,
                    quiet_result=True,
                )
                resource = self._resource_from_task(resource, task)
                if task:
                    self.tasks.display_result(task)
            elif choice == "2":
                self._open(resource)
            elif choice == "3":
                self.tasks.run_capability(
                    self.tasks.capability("port-manager", "storage-plan"),
                    resource_id=resource_id,
                    timeout_seconds=180,
                )
            elif choice == "4":
                resource = self._login(resource)
            else:
                print("请输入 0 到 4。")

    def login_gate(self) -> None:
        result = self.app.port_manager.list_resources()
        if not result.success:
            self.io.failure(result.message, result.error_code, "先修复端口管理服务")
            return
        resources = result.data if isinstance(result.data, list) else []
        counts = resource_counts(resources)
        print("\n慧策资源与登录状态")
        print(
            f"可继续 {counts['可用']}，需登录 {counts['需登录']}，"
            f"未验证 {counts['未验证']}，不可用/需修复 {counts['异常']}"
        )
        if not resources:
            print("当前没有资源，无法判断登录状态。")
            return
        for index, item in enumerate(resources, 1):
            state = str(item.get("state") or "未验证")
            print(
                f"{index}. {item.get('resourceId')} / 端口 {item.get('port')}："
                f"{state}，{STATE_HINTS.get(state, '请先检查状态')}"
            )
        print("输入资源序号可查看并处理；直接回车返回。")
        choice = self.io.input("资源序号", allow_empty=True)
        if not choice:
            return
        resource = self.io.selected(resources, choice)
        if resource is None:
            print("资源序号无效。")
            return
        self.detail(resource)

    def _open(self, resource: dict[str, Any]) -> None:
        resource_id = str(resource.get("resourceId") or "")
        capability = self.tasks.capability("port-manager", "open-resource")
        if not self.io.confirm(f"{capability.confirmation_text} {resource_id}？这可能启动或切换 Chrome。"):
            print("已取消，没有操作浏览器。")
            return
        print(f"{capability.progress_text}，请稍候……")
        result = self.app.port_manager.open_resource(resource_id)
        self.app.tasks.append(
            "open-resource",
            "成功" if result.success else "失败",
            result.message or "资源打开结束",
            module_id="port-manager",
            resource_id=resource_id,
            write_level="service-state-write",
        )
        if result.success:
            print(f"打开结果：{result.message or '资源已打开或复用'}")
            print("下一步：返回资源详情重新检查登录状态。")
        else:
            self.io.failure(result.message, result.error_code, capability.failure_next_action)

    def _login(self, resource: dict[str, Any]) -> dict[str, Any]:
        resource_id = str(resource.get("resourceId") or "")
        if resource.get("state") == "可用":
            print("该资源当前可用，无需重新登录。")
            return resource
        capability = self.tasks.capability("port-manager", "login-resource")
        if not self.io.confirm(
            f"{capability.confirmation_text}？程序可能打开 Chrome，并在 PowerShell 安全读取登录信息。"
        ):
            print("已取消登录。")
            return resource
        print("正在进入正式登录；请按屏幕提示完成必要输入或外部安全验证。")
        code = self.app.port_manager.login_resource_interactive(resource_id)
        self.app.tasks.append(
            "resource-login",
            "成功" if code == 0 else "失败",
            "正式登录入口执行完成，等待状态复核" if code == 0 else "正式登录未完成",
            module_id="port-manager",
            resource_id=resource_id,
            write_level="service-state-write",
        )
        if code != 0:
            print("登录未完成。请根据刚才的中文提示处理后重试。")
            return resource
        print("登录入口已结束，正在重新检查真实状态……")
        task = self.tasks.run_capability(
            self.tasks.capability("port-manager", "check-resource"),
            resource_id=resource_id,
            timeout_seconds=90,
            quiet_result=True,
        )
        return self._resource_from_task(resource, task)

    def _resource_from_task(
        self, resource: dict[str, Any], task: dict[str, Any] | None
    ) -> dict[str, Any]:
        if not isinstance(task, dict):
            return resource
        result = task.get("result")
        if not isinstance(result, dict) or not isinstance(result.get("resource"), dict):
            return resource
        checked = self.app.port_manager.sanitize_checked(
            result["resource"], base_resource=resource
        )
        return self.app.port_manager.merge_resource_state(resource, checked)

    @staticmethod
    def _print_list(resources: list[dict[str, Any]]) -> None:
        for index, item in enumerate(resources, 1):
            state = item.get("state") or "未验证"
            print(f"{index}. {item.get('resourceId')} / 端口 {item.get('port')}：{state}")
            print(
                f"   {item.get('summary')}；下一步："
                f"{STATE_HINTS.get(str(state), '请先检查状态')}"
            )

    @staticmethod
    def _print_detail(resource: dict[str, Any]) -> None:
        print("\n资源详情")
        print(f"资源编号：{resource.get('resourceId')}")
        print(f"名称：{resource.get('name') or resource.get('resourceName') or '未命名'}")
        print(f"平台：{resource.get('platform') or resource.get('platformName') or '未标明'}")
        print(f"端口：{resource.get('port')}")
        print(f"当前状态：{resource.get('state') or '未验证'}")
        print(f"端口连接：{resource.get('connectionStatus') or '未检查'}")
        print(f"登录状态：{resource.get('loginStatus') or '状态未知'}")
        print(f"只读接口：{resource.get('apiStatus') or '未检查'}")
        print(f"最近检查：{resource.get('checkedAt') or '尚未检查'}")
        print(f"下一步：{STATE_HINTS.get(str(resource.get('state')), '请先检查状态')}")
