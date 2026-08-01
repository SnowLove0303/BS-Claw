from __future__ import annotations

import time
from typing import Any

from .capabilities import CapabilityCatalog, UserCapability
from .console_common import ConsoleIO
from .scheduler_models import STATE_WAITING_MANUAL, TERMINAL_STATES
from .scheduler_store import SchedulerDataError


FINISHED_STATES = set(TERMINAL_STATES) | {STATE_WAITING_MANUAL}


class TaskConsole:
    """Reusable task execution and presentation for service and workflow plugins."""

    def __init__(self, application: Any) -> None:
        self.app = application
        self.io = ConsoleIO()
        self.catalog = CapabilityCatalog(application.module_registry)

    def capability(self, module_id: str, capability_id: str) -> UserCapability:
        return self.catalog.get(module_id, capability_id)

    def run_capability(
        self,
        capability: UserCapability,
        *,
        resource_id: str = "",
        timeout_seconds: int = 90,
        quiet_result: bool = False,
    ) -> dict[str, Any] | None:
        if capability.requires_confirmation and not self.io.confirm(
            capability.confirmation_text or f"确认执行“{capability.display_name}”吗？"
        ):
            print("已取消，没有执行操作。")
            return None
        print(f"\n{capability.progress_text}，请稍候……")
        try:
            task = self.app.scheduler.submit(
                module_id=capability.module_id,
                action=capability.action,
                parameters={},
                resource_id=resource_id,
                timeout_seconds=timeout_seconds,
            )
            task = self.wait(task, timeout_seconds)
        except SchedulerDataError as exc:
            self.io.failure(
                str(exc), "SCHEDULER_REQUEST_REJECTED", capability.failure_next_action
            )
            return None
        if not quiet_result:
            self.display_result(task)
        return task

    def wait(self, task: dict[str, Any], timeout_seconds: int) -> dict[str, Any]:
        task_id = str(task.get("taskId") or "")
        deadline = time.monotonic() + timeout_seconds + 10
        last_message = ""
        heartbeat = 0.0
        try:
            while task.get("state") not in FINISHED_STATES and time.monotonic() < deadline:
                message = f"{task.get('state')}：{task.get('summary')}"
                now = time.monotonic()
                if message != last_message or now >= heartbeat:
                    print(f"- {message}")
                    last_message = message
                    heartbeat = now + 8
                time.sleep(0.4)
                task = self.app.scheduler.result(task_id)
        except KeyboardInterrupt:
            print("\n收到取消请求，正在停止任务……")
            try:
                return self.app.scheduler.cancel(task_id)
            except SchedulerDataError:
                return self.app.scheduler.result(task_id)
        if task.get("state") not in FINISHED_STATES:
            print("任务仍在后台执行，可稍后从任务中心查看。")
        return self.app.scheduler.result(task_id)

    def display_result(self, task: dict[str, Any]) -> None:
        print(f"结果：{task.get('state') or '未验证'}")
        print(f"说明：{task.get('summary') or '暂无结果摘要'}")
        result = task.get("result")
        if isinstance(result, dict):
            if "resourceCount" in result:
                print(f"资源数量：{result.get('resourceCount')}")
            totals = result.get("totals")
            if isinstance(totals, dict):
                print(
                    "可再生缓存："
                    f"{self.io.format_bytes(int(totals.get('reproducibleChromeCacheBytes') or 0))}"
                )
                print(
                    "需保留的 Profile 数据："
                    f"{self.io.format_bytes(int(totals.get('nonCacheProfileBytes') or 0))}"
                )
                print("本次只做存储盘点，不会删除数据。")
        if task.get("errorCode"):
            print(f"错误类型：{task.get('errorCode')}")
        print(f"下一步：{self.io.friendly_next_action(task)}")

    def center(self) -> None:
        while True:
            tasks = self.app.scheduler.list(20)
            resource_names = self._resource_names()
            print("\n任务中心")
            if not tasks:
                print("暂无任务。")
                return
            for index, task in enumerate(tasks, 1):
                module_name = self.catalog.module_name(str(task.get("moduleId") or ""))
                action_name = self._action_name(task)
                when = self.io.short_time(task.get("updatedAt") or task.get("createdAt"))
                print(f"{index}. {action_name} / {module_name}：{task.get('state')} / {when}")
                if task.get("resourceId"):
                    resource_id = str(task.get("resourceId"))
                    print(
                        f"   资源：{resource_names.get(resource_id, '未命名资源')}"
                        f"（{resource_id}）"
                    )
                print(f"   影响：{self._write_level_text(task)}")
                print(
                    "   时间："
                    f"{self.io.short_time(task.get('startedAt') or task.get('createdAt'))}"
                    f" → {self.io.short_time(task.get('finishedAt')) if task.get('finishedAt') else '进行中'}"
                )
                print(f"   {task.get('summary') or '暂无结果摘要'}")
                if self._is_development_record(task):
                    print("   说明：这是开发或审计检查记录，不影响菜单中的正常操作。")
            print("R. 刷新   0. 返回")
            choice = self.io.input("请选择任务序号").lower()
            if choice == "0":
                return
            if choice == "r":
                continue
            task = self.io.selected(tasks, choice)
            if task is None:
                print("请选择列表中的有效序号。")
                continue
            self._detail(task)

    def _detail(self, task: dict[str, Any]) -> None:
        try:
            task = self.app.scheduler.result(str(task.get("taskId") or ""))
        except SchedulerDataError as exc:
            print(f"任务详情读取失败：{exc}")
            return
        print(f"\n{self._action_name(task)}")
        print(f"所属模块：{self.catalog.module_name(str(task.get('moduleId') or ''))}")
        if task.get("resourceId"):
            print(f"资源：{task.get('resourceId')}")
        print(f"影响范围：{self._write_level_text(task)}")
        print(f"开始：{self.io.short_time(task.get('startedAt') or task.get('createdAt'))}")
        print(f"结束：{self.io.short_time(task.get('finishedAt')) if task.get('finishedAt') else '尚未结束'}")
        print(f"状态：{task.get('state')}")
        print(f"结果：{task.get('summary') or '暂无结果摘要'}")
        if self._is_development_record(task):
            print("说明：这是开发或审计检查记录，不影响菜单中的正常操作。")
        print(f"下一步：{self.io.friendly_next_action(task)}")
        if task.get("needsManualAction"):
            print("人工处理：需要")
        print("技术信息（反馈问题时使用）：")
        print(f"- 任务编号：{task.get('taskId')}")
        print(f"- 审计编号：{task.get('auditId')}")
        print(f"- 错误码：{task.get('errorCode') or '无'}")
        if task.get("state") not in FINISHED_STATES:
            if self.io.confirm("是否取消这个未完成任务？"):
                try:
                    cancelled = self.app.scheduler.cancel(str(task["taskId"]))
                    print(f"取消结果：{cancelled.get('summary')}")
                except SchedulerDataError as exc:
                    print(f"无法取消：{exc}")
        elif (
            not self._is_development_record(task)
            and task.get("retryable")
            and not task.get("businessWritesExecuted")
        ):
            if self.io.confirm("是否安全重试这个任务？"):
                try:
                    retried = self.app.scheduler.retry(str(task["taskId"]))
                    self.wait(retried, int(retried.get("timeoutSeconds") or 90))
                except SchedulerDataError as exc:
                    print(f"无法重试：{exc}")

    def _action_name(self, task: dict[str, Any]) -> str:
        module_id = str(task.get("moduleId") or "")
        action = str(task.get("action") or "")
        try:
            return self.catalog.get(module_id, action).display_name
        except KeyError:
            return {
                "ACTION_NOT_SUPPORTED": "不支持的操作请求",
                "MODULE_NOT_FOUND": "未接入模块请求",
            }.get(str(task.get("errorCode") or ""), "系统记录")

    @staticmethod
    def _is_development_record(task: dict[str, Any]) -> bool:
        return str(task.get("errorCode") or "") in {
            "ACTION_NOT_SUPPORTED",
            "MODULE_NOT_FOUND",
            "MODULE_MANIFEST_INVALID",
            "MODULE_ENTRY_NOT_FOUND",
        }

    def _resource_names(self) -> dict[str, str]:
        result = self.app.port_manager.list_resources()
        items = result.data if result.success and isinstance(result.data, list) else []
        return {
            str(item.get("resourceId")): str(
                item.get("name") or item.get("resourceName") or "未命名资源"
            )
            for item in items
            if item.get("resourceId")
        }

    @staticmethod
    def _write_level_text(task: dict[str, Any]) -> str:
        return {
            "pure-read": "仅展示，不写服务状态或业务数据",
            "service-state-write": "更新服务运行状态，不写外部业务",
            "business-write": "可能写入外部业务",
        }.get(str(task.get("writeLevel") or "pure-read"), "未声明")
