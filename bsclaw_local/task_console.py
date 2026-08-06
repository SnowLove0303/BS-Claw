from __future__ import annotations

import json
import time
from typing import Any

from .capabilities import CapabilityCatalog, UserCapability
from .console_common import ConsoleIO
from .scheduler_models import (
    STATE_WAITING_EXTERNAL_VERIFICATION,
    STATE_WAITING_LOGIN,
    STATE_WAITING_MANUAL,
    STATE_WAITING_RESOURCE,
    TERMINAL_STATES,
)
from .scheduler_store import SchedulerDataError
from .resource_selector import ResourceSelector


FINISHED_STATES = set(TERMINAL_STATES) | {
    STATE_WAITING_MANUAL,
    STATE_WAITING_RESOURCE,
    STATE_WAITING_LOGIN,
    STATE_WAITING_EXTERNAL_VERIFICATION,
}


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
        parameters: dict[str, Any] | None = None,
        skip_confirmation: bool = False,
    ) -> dict[str, Any] | None:
        if capability.requires_resource and not resource_id:
            resource_id = self._select_resource_for_capability(capability)
            if not resource_id:
                return None
        if capability.requires_confirmation and not skip_confirmation and not self.io.confirm(
            capability.confirmation_text or f"确认执行“{capability.display_name}”吗？"
        ):
            print("已取消，没有执行操作。")
            return None
        print(f"\n{capability.progress_text}，请稍候……")
        try:
            task = self.app.scheduler.submit(
                module_id=capability.module_id,
                action=capability.action,
                parameters=parameters or {},
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

    def _select_resource_for_capability(self, capability: UserCapability) -> str:
        """Bind a human-readable selection to an internal resource id.

        The id never becomes a user input. It is selected from the current
        public PortManager list and carried only in scheduler context.
        """
        if capability.resource_selection_mode in {"multi", "all"}:
            selected = ResourceSelector(self.app, self.io).select(capability.resource_selection_mode)
            if not selected:
                return ""
            count = len(selected) if isinstance(selected, list) else 1
            self.io.failure(
                f"已选择 {count} 个资源，但当前动作的多资源执行策略尚未声明为可执行。",
                "RESOURCE_SELECTION_UNSUPPORTED",
                "请改用已声明单资源策略的动作，或等待模块声明可执行的多资源策略。",
            )
            return ""
        selected = ResourceSelector(self.app, self.io).select("single")
        return str(selected.get("resourceId") or "") if isinstance(selected, dict) else ""

    def wait(self, task: dict[str, Any], timeout_seconds: int) -> dict[str, Any]:
        task_id = str(task.get("taskId") or "")
        deadline = time.monotonic() + timeout_seconds + 10
        last_message = ""
        heartbeat = 0.0
        try:
            while task.get("state") not in FINISHED_STATES and time.monotonic() < deadline:
                message = self._progress_text(task)
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
        print(f"结果：{self._state_text(task.get('state'))}")
        print(f"说明：{task.get('summary') or '暂无结果摘要'}")
        result = task.get("result")
        if isinstance(result, dict):
            if "resourceCount" in result:
                print(f"资源数量：{result.get('resourceCount')}")
            outcomes = result.get("outcomes")
            if isinstance(outcomes, dict):
                print(
                    "资源检查结果："
                    f"可用 {outcomes.get('ready', 0)}，"
                    f"需登录 {outcomes.get('login-required', 0)}，"
                    f"需修复 {outcomes.get('repair-required', 0)}，"
                    f"连接不可用 {outcomes.get('unavailable', 0)}，"
                    f"未验证 {outcomes.get('unknown', 0)}"
                )
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
            selected = result.get("selected")
            if isinstance(selected, dict):
                print("目标商品：")
                print(f"- 名称：{selected.get('goodsName') or selected.get('name') or '未返回'}")
                print(f"- 来源：{selected.get('sourcePath') or selected.get('sourceInterface') or '未返回'}")
                print(f"- 读取时间：{selected.get('sourceReadAt') or result.get('readbackAt') or '未返回'}")
            write_summary = result.get("writeSummary")
            if isinstance(write_summary, dict):
                print("加入分销提交：")
                print(f"- 状态：{write_summary.get('status') or ('成功' if write_summary.get('success') else '失败')}")
                print(f"- 来源接口：{write_summary.get('sourcePath') or '未返回'}")
            readback_summary = result.get("readbackSummary")
            if isinstance(readback_summary, dict):
                print("结果回查：")
                print(f"- 状态：{readback_summary.get('status') or ('已确认' if readback_summary.get('success') else '未确认')}")
                print(f"- 回查接口：{readback_summary.get('sourcePath') or '未返回'}")
                print(f"- 回查时间：{readback_summary.get('checkedAt') or result.get('readbackAt') or '未返回'}")
            lease = result.get("resourceLease")
            if isinstance(lease, dict):
                release = lease.get("release") if isinstance(lease.get("release"), dict) else {}
                print(f"资源租约：{'已释放' if release.get('success') else '未确认释放'}")
        print(f"下一步：{self.io.friendly_next_action(task)}")

    def run_hot_add_distribution(self) -> dict[str, Any] | None:
        """Run the fixed user path: hot goods -> select one -> add distribution."""
        try:
            capability = self.capability("huice-selection-phase1", "hot.add-distribution")
        except KeyError as exc:
            self.io.failure(
                "慧策找爆款加入分销模块尚未被自动发现。",
                "SELECTION_MODULE_NOT_DISCOVERED",
                "检查 SelectionModule-Phase1 manifest 和 BSClaw-Local 模块发现目录后重试。",
            )
            return None
        return self.run_capability(
            capability,
            timeout_seconds=600,
            skip_confirmation=True,
            parameters={
                "writeAuthorization": {
                    "scope": "isolated-resource",
                    "status": "approved",
                    "source": "TaskContractId SEL-HOT-ADD-DIST-20260802-R2",
                },
                "pathContract": "hot-goods-recommend-to-selection-v1",
            },
        )

    def continue_interactive_login(self, resource_id: str) -> int:
        """Continue the explicitly user-approved login stage through the PM adapter."""
        return self.app.port_manager.login_resource_interactive(resource_id)

    def open_login_intervention(self, resource: dict[str, Any], reason: str) -> dict[str, Any]:
        from .intervention_gateway import InterventionGateway

        gateway = InterventionGateway()
        result = gateway.open(
            {
                "taskName": "慧策正式登录",
                "resource": f"{resource.get('name') or resource.get('resourceName') or '未命名资源'} / 端口 {resource.get('port') or '未知'}",
                "reason": reason,
                "mode": "login",
                "localRoot": str(self.app.paths.local_root),
                "windowScript": str(self.app.paths.local_root / "bsclaw_local" / "intervention_window.ps1"),
            }
        )
        if result.action != "submit":
            return {
                "success": False,
                "status": result.action,
                "errorCode": "INTERVENTION_" + result.action.upper(),
                "message": "用户未提交登录信息，原任务未继续",
                "data": {},
            }
        try:
            return self.app.port_manager.login_resource_with_credentials(
                str(resource.get("resourceId") or ""), result.values
            )
        finally:
            for key in list(result.values):
                result.values[key] = ""

    def open_verification_intervention(self, resource: dict[str, Any], reason: str) -> str:
        from .intervention_gateway import InterventionGateway

        result = InterventionGateway().open(
            {
                "taskName": "慧策登录安全验证",
                "resource": f"{resource.get('name') or resource.get('resourceName') or '未命名资源'} / 端口 {resource.get('port') or '未知'}",
                "reason": reason,
                "mode": "verification",
                "localRoot": str(self.app.paths.local_root),
                "windowScript": str(self.app.paths.local_root / "bsclaw_local" / "intervention_window.ps1"),
            }
        )
        return result.action

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
                    )
                print(f"   影响：{self._write_level_text(task)}")
                print(
                    "   时间："
                    f"{self.io.short_time(task.get('startedAt') or task.get('createdAt'))}"
                    f" → {self.io.short_time(task.get('finishedAt')) if task.get('finishedAt') else '进行中'}"
                )
                self._print_progress(task, prefix="   ")
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

    def pending_manual_count(self) -> int:
        """Return waiting tasks for the user-facing intervention badge."""
        tasks = self._manual_tasks()
        count = len(tasks)
        known_resources = {str(task.get("resourceId") or "") for task in tasks}
        pending_dir = self.app.paths.data_root / "login-interventions"
        if pending_dir.is_dir():
            for path in pending_dir.glob("*.json"):
                try:
                    record = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                resource_id = str(record.get("resourceId") or "") if isinstance(record, dict) else ""
                if isinstance(record, dict) and record.get("status") in {
                    "waiting-external-verification", "resuming"
                } and resource_id not in known_resources:
                    count += 1
        return count

    def manual_center(self) -> None:
        """User-facing queue for tasks waiting on a person.

        The user never needs to know a task id. Selecting an item opens the
        same continuation entry used by task details.
        """
        while True:
            tasks = self._manual_tasks()
            print("\n待处理人工事项")
            if not tasks:
                print("当前没有等待人工处理的任务。")
                return
            for index, task in enumerate(tasks, 1):
                print(
                    f"{index}. {self._action_name(task)} / "
                    f"{self._resource_names().get(str(task.get('resourceId') or ''), '未指定资源')} / "
                    f"{self._state_text(task.get('state'))}"
                )
                print(f"   原因：{task.get('summary') or '需要人工确认或输入'}")
            print("0. 返回")
            choice = self.io.input("请选择要处理的事项").lower()
            if choice == "0":
                return
            task = self.io.selected(tasks, choice)
            if task is not None:
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
            resource_id = str(task.get("resourceId"))
            print(f"资源：{self._resource_names().get(resource_id, '未命名资源')}")
        print(f"影响范围：{self._write_level_text(task)}")
        print(f"开始：{self.io.short_time(task.get('startedAt') or task.get('createdAt'))}")
        print(f"结束：{self.io.short_time(task.get('finishedAt')) if task.get('finishedAt') else '尚未结束'}")
        print(f"状态：{task.get('state')}")
        self._print_progress(task)
        print(f"结果：{task.get('summary') or '暂无结果摘要'}")
        if self._is_development_record(task):
            print("说明：这是开发或审计检查记录，不影响菜单中的正常操作。")
        print(f"下一步：{self.io.friendly_next_action(task)}")
        if self._is_manual_wait(task):
            self._manual_entry(task)
            return
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

    def _manual_entry(self, task: dict[str, Any]) -> None:
        """Expose a visible continuation/cancel entry for every manual wait."""
        resource_name = self._resource_names().get(
            str(task.get("resourceId") or ""), "未指定资源"
        )
        print("\n人工处理入口")
        print(f"任务：{self._action_name(task)}")
        print(f"资源：{resource_name}")
        print(f"等待原因：{task.get('summary') or '需要人工输入、验证或授权'}")
        print("1. 进入正式输入/授权并完成后自动继续")
        print("2. 取消等待并释放本次任务")
        print("0. 返回")
        choice = self.io.input("请选择").strip().lower()
        if choice == "1":
            self._resume_manual(task)
        elif choice == "2":
            try:
                cancelled = self.app.scheduler.cancel(str(task.get("taskId") or ""))
                print(f"已取消：{cancelled.get('summary') or '任务已取消'}")
            except SchedulerDataError as exc:
                print(f"取消失败：{exc}")

    def _resume_manual(self, task: dict[str, Any]) -> None:
        resource_id = str(task.get("resourceId") or "")
        resource: dict[str, Any] | None = None
        if resource_id:
            resources = self.app.port_manager.list_resources().data
            resource = next(
                (item for item in resources if str(item.get("resourceId") or "") == resource_id),
                None,
            ) if isinstance(resources, list) else None
            if resource is None:
                print("原资源已不存在或无法读取，请先刷新端口资源。")
                return
        else:
            resource = {"name": "当前任务", "port": "未指定"}
        if resource_id and str(task.get("errorCode") or "") in {
            "LOGIN_REQUIRED", "LOGIN_INTERACTIVE_REQUIRED", "SESSION_EXPIRED",
            "IMAGE_CAPTCHA_REQUIRED", "SMS_VERIFICATION_REQUIRED", "MOBILE_BIND_REQUIRED",
        }:
            self.app.resources._login(resource, waiting_task=task)
            return
        action = self.open_verification_intervention(
            resource,
            str(task.get("summary") or "需要完成业务确认或外部验证"),
        )
        if action != "continue":
            try:
                self.app.scheduler.cancel(str(task.get("taskId") or ""))
            except SchedulerDataError:
                pass
            print("人工处理已取消，原任务已结束并释放占用。")
            return
        resumed = self.app.scheduler.retry(str(task.get("taskId") or ""))
        self.wait(resumed, int(resumed.get("timeoutSeconds") or 90))

    @staticmethod
    def _is_manual_wait(task: dict[str, Any]) -> bool:
        if not (task.get("needsManualAction") or task.get("state") in {
            STATE_WAITING_MANUAL,
            STATE_WAITING_LOGIN,
            STATE_WAITING_EXTERNAL_VERIFICATION,
        }):
            return False
        code = str(task.get("errorCode") or "")
        popup_codes = {
            "LOGIN_REQUIRED", "LOGIN_INTERACTIVE_REQUIRED", "SESSION_EXPIRED",
            "IMAGE_CAPTCHA_REQUIRED", "SMS_VERIFICATION_REQUIRED", "MOBILE_BIND_REQUIRED",
            "EXTERNAL_VERIFICATION_REQUIRED", "SERVICE_AGREEMENT_CONFIRMATION_REQUIRED",
            "RESOURCE_AUTHORIZATION_REQUIRED", "HIGH_RISK_CONFIRMATION_REQUIRED",
            "BUSINESS_CONFIRMATION_REQUIRED",
        }
        if code not in popup_codes:
            return False
        if str(task.get("state") or "") == "未验证":
            summary = str(task.get("summary") or "")
            if code in {"PROGRAM_RESTART_UNVERIFIED", "RECOVERY_UNVERIFIED"} or "程序重启" in summary:
                return False
        return True

    def _manual_tasks(self) -> list[dict[str, Any]]:
        """Return true human waits, de-duplicated by the pending action."""
        unique: dict[tuple[str, str, str], dict[str, Any]] = {}
        for task in self.app.scheduler.list(200):
            if not self._is_manual_wait(task):
                continue
            key = (
                str(task.get("resourceId") or ""),
                str(task.get("action") or ""),
                str(task.get("errorCode") or "MANUAL"),
            )
            unique.setdefault(key, task)
        return list(unique.values())

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
        items = self.app.cached_resources()
        return {
            str(item.get("resourceId")): str(
                f"{item.get('name') or item.get('resourceName') or '未命名资源'} / 端口 {item.get('port') or '未知'}"
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

    @staticmethod
    def _state_text(value: Any) -> str:
        return {
            "成功": "已完成",
            "执行中": "执行中",
            "预检中": "准备中",
            "等待回查": "等待结果确认",
            "等待人工处理": "等待人工处理",
            "阻断": "未执行（已阻断）",
            "失败": "执行失败",
            "超时": "执行超时",
            "已取消": "已取消",
            "未验证": "未验证",
        }.get(str(value or ""), str(value or "未验证"))

    @classmethod
    def _progress_text(cls, task: dict[str, Any]) -> str:
        progress = task.get("progress")
        if isinstance(progress, dict):
            total = progress.get("total")
            completed = progress.get("completed")
            failed = progress.get("failed")
            current = progress.get("currentResourceId") or ""
            if total is not None and completed is not None:
                suffix = f"，已完成 {completed}/{total}，失败 {failed or 0}"
                if current:
                    suffix += "，当前资源处理中"
                return f"{cls._state_text(task.get('state'))}{suffix}"
        return f"{cls._state_text(task.get('state'))}：{task.get('summary') or '正在处理'}"

    @staticmethod
    def _print_progress(task: dict[str, Any], prefix: str = "") -> None:
        progress = task.get("progress")
        if not isinstance(progress, dict):
            return
        total = progress.get("total")
        completed = progress.get("completed")
        failed = progress.get("failed")
        if total is None or completed is None:
            return
        text = f"{prefix}进度：已完成 {completed}/{total}，失败 {failed or 0}"
        current = progress.get("currentResourceId")
        if current:
            text += "，当前资源处理中"
        print(text)
