from __future__ import annotations

import json
from datetime import datetime, timezone
from typing import Any

from .console_common import ConsoleIO, STATE_HINTS, resource_counts
from .scheduler_models import STATE_FAILED, STATE_PREFLIGHT, STATE_SUCCEEDED, TERMINAL_STATES
from .task_console import TaskConsole


class ResourceConsole:
    """PortManager user pages; all service calls stay behind public adapters."""

    def __init__(self, application: Any, tasks: TaskConsole) -> None:
        self.app = application
        self.tasks = tasks
        self.io = ConsoleIO()

    def center(self) -> None:
        force_refresh = True
        while True:
            result = self.app.port_manager.list_resources(force_refresh=force_refresh)
            force_refresh = False
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
            print("R. 刷新列表   0. 返回")
            choice = self.io.input("请选择资源序号").lower()
            if choice == "0":
                return
            if choice == "r":
                force_refresh = True
                continue
            resource = self.io.selected(resources, choice)
            if resource is None:
                print("请选择列表中的有效序号。")
                continue
            self.detail(resource)

    def detail(self, resource: dict[str, Any]) -> None:
        resource_id = str(resource.get("resourceId") or "")
        while True:
            resource_id = str(resource.get("resourceId") or resource_id)
            pending_path = self.app.paths.data_root / "login-interventions" / f"{resource_id}.json"
            try:
                pending = json.loads(pending_path.read_text(encoding="utf-8")) if pending_path.is_file() else None
                resource["interventionStatus"] = pending.get("status") if isinstance(pending, dict) else None
            except (OSError, ValueError):
                resource["interventionStatus"] = None
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
                self.app.port_manager.invalidate_cache()
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
        result = self.app.port_manager.list_resources(force_refresh=True)
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
            print(
                f"   连接：{item.get('connectionStatus') or '未检查'} / "
                f"页面：{item.get('pageStatus') or '未检查'} / "
                f"登录：{item.get('loginStatus') or '未检查'} / "
                f"API：{item.get('apiStatus') or '未检查'} / "
                f"时间：{item.get('checkedAt') or item.get('snapshotAt') or '无'} / "
                f"新鲜度：{item.get('freshness') or 'never-checked'}"
            )
            state = str(item.get("state") or "未验证")
            name = item.get("name") or item.get("resourceName") or "未命名资源"
            print(
                f"{index}. {name} / 端口 {item.get('port')}："
                f"{state}，{STATE_HINTS.get(state, '请先检查状态')}"
            )
        print("输入资源序号可查看并处理；输入 R 刷新真实状态，直接回车返回。")
        choice = self.io.input("资源序号", allow_empty=True)
        if choice.lower() == "r":
            result = self.app.port_manager.list_resources(force_refresh=True)
            resources = result.data if result.success and isinstance(result.data, list) else []
            print("已重新读取端口管理状态，请再次选择资源。")
            for index, item in enumerate(resources, 1):
                name = item.get("name") or item.get("resourceName") or "未命名资源"
                print(f"{index}. {name} / 端口 {item.get('port')}：{item.get('state')}（{item.get('freshness')}）")
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
        label = self._resource_label(resource)
        capability = self.tasks.capability("port-manager", "open-resource")
        if not self.io.confirm(f"{capability.confirmation_text}“{label}”？这可能启动或切换 Chrome。"):
            print("已取消，没有操作浏览器。")
            return
        task = self.tasks.run_capability(
            capability,
            resource_id=resource_id,
            timeout_seconds=45,
            quiet_result=True,
        )
        if task and task.get("state") == "成功":
            print("打开结果：资源已打开或复用。")
            refreshed = self._resource_from_task(resource, task)
            login_state = str(refreshed.get("state") or "")
            if login_state == "需登录" or str(refreshed.get("loginStatus") or "").lower() in {"login-required", "未登录", "登录已过期"}:
                print("当前资源尚未登录。")
                if self.io.confirm("是否现在进入正式登录？"):
                    return self._login(refreshed)
                print("已返回资源详情；如需登录，可再次选择“进入正式登录”。")
            else:
                print("下一步：返回资源详情查看最新连接和登录状态。")
        elif task:
            self.tasks.display_result(task)

    def _login(
        self, resource: dict[str, Any], waiting_task: dict[str, Any] | None = None
    ) -> dict[str, Any]:
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
        task = self.tasks.run_capability(
            capability,
            resource_id=resource_id,
            timeout_seconds=30,
            quiet_result=True,
        )
        if not task or task.get("errorCode") != "LOGIN_INTERACTIVE_REQUIRED":
            if task:
                self.tasks.display_result(task)
            return resource
        print("已打开独立人工处理窗口，请在窗口中完成安全输入；关闭窗口不会结束程序，取消会释放等待任务。")
        login_result = self.tasks.open_login_intervention(resource, "请输入企业账号、操作员账号和密码，并确认服务协议")
        if not login_result.get("success"):
            print("登录入口未完成，正在回查真实资源状态……")
            check = self.tasks.run_capability(
                self.tasks.capability("port-manager", "check-resource"),
                resource_id=resource_id,
                timeout_seconds=90,
                quiet_result=True,
            )
            if check:
                checked_resource = self._resource_from_task(resource, check)
                error_code = str(login_result.get("errorCode") or check.get("errorCode") or "")
                if error_code in {"CDP_COMMAND_TIMEOUT", "CDP_TIMEOUT", "CDP_UNAVAILABLE"}:
                    print("登录失败：浏览器调试连接或页面响应超时；资源未标记为已登录。请确认该资源浏览器仍在运行后重试。")
                elif error_code in {"IMAGE_CAPTCHA_REQUIRED", "SMS_VERIFICATION_REQUIRED", "MOBILE_BIND_REQUIRED"}:
                    return self._wait_for_login_intervention(resource, check, error_code, waiting_task)
                elif error_code:
                    print(f"登录未完成：{check.get('summary') or '登录状态未就绪'}（已分类为 {error_code}，未记录凭据）。")
                else:
                    print("登录未完成：页面/API 状态仍未达到可用，请按提示重试。")
                if waiting_task:
                    self._complete_waiting_task(waiting_task, checked_resource)
                return checked_resource
            print("登录未完成：无法取得真实状态回查；请先检查端口连接后重试。")
            return resource
        print("登录入口已结束，正在重新检查真实状态……")
        task = self.tasks.run_capability(
            self.tasks.capability("port-manager", "check-resource"),
            resource_id=resource_id,
            timeout_seconds=90,
            quiet_result=True,
        )
        checked = self._resource_from_task(resource, task)
        if waiting_task and task:
            self._complete_waiting_task(waiting_task, checked)
        return checked

    def _wait_for_login_intervention(
        self,
        resource: dict[str, Any],
        task: dict[str, Any],
        error_code: str,
        waiting_task: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Keep the user in the same login flow without persisting secrets.

        The waiting record contains only a resource reference, error category
        and timestamps. Credentials and verification values never enter it.
        """
        resource_id = str(resource.get("resourceId") or "")
        pending_dir = self.app.paths.data_root / "login-interventions"
        pending_dir.mkdir(parents=True, exist_ok=True)
        pending_path = pending_dir / f"{resource_id or 'selected'}.json"
        pending = {
            "resourceId": resource_id,
            "status": "waiting-external-verification",
            "errorCode": error_code,
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "updatedAt": datetime.now(timezone.utc).isoformat(),
            "nextAction": "完成慧策页面安全验证后，在当前提示输入继续",
        }
        pending_path.write_text(json.dumps(pending, ensure_ascii=False, indent=2), encoding="utf-8")
        print("已打开独立人工处理窗口，请在同一资源页面完成验证后点击“继续”。")
        answer = self.tasks.open_verification_intervention(resource, "慧策页面要求验证码、短信或外部风控验证")
        if answer != "continue":
            pending["status"] = "cancelled"
            pending["updatedAt"] = datetime.now(timezone.utc).isoformat()
            pending["nextAction"] = "可从资源详情重新进入正式登录"
            pending_path.write_text(json.dumps(pending, ensure_ascii=False, indent=2), encoding="utf-8")
            print("已取消等待，登录租约将由正式入口释放。")
            if waiting_task:
                try:
                    self.app.scheduler.cancel(str(waiting_task.get("taskId") or ""))
                except Exception:
                    pass
            return resource
        pending["status"] = "resuming"
        pending["updatedAt"] = datetime.now(timezone.utc).isoformat()
        pending_path.write_text(json.dumps(pending, ensure_ascii=False, indent=2), encoding="utf-8")
        resumed = self.tasks.run_capability(
            self.tasks.capability("port-manager", "check-resource"),
            resource_id=resource_id,
            timeout_seconds=90,
            quiet_result=True,
        )
        pending["status"] = "completed" if resumed and resumed.get("state") == "成功" else "failed"
        pending["updatedAt"] = datetime.now(timezone.utc).isoformat()
        pending["nextAction"] = "可继续使用当前资源" if pending["status"] == "completed" else "完成验证后重新检查"
        pending_path.write_text(json.dumps(pending, ensure_ascii=False, indent=2), encoding="utf-8")
        if resumed:
            self.tasks.display_result(resumed)
            checked = self._resource_from_task(resource, resumed)
            if waiting_task:
                self._complete_waiting_task(waiting_task, checked)
            return checked
        return resource

    def _complete_waiting_task(self, waiting_task: dict[str, Any], resource: dict[str, Any]) -> None:
        """Continue the original waiting task without exposing an internal id."""
        task_id = str(waiting_task.get("taskId") or "")
        if not task_id:
            return
        try:
            raw = self.app.scheduler.store.load(task_id)
            if str(raw.get("state") or "") in TERMINAL_STATES:
                return
            if str(waiting_task.get("action") or "") == "login-resource":
                state = str(resource.get("state") or "")
                login_status = str(resource.get("loginStatus") or "").lower()
                api_status = str(resource.get("apiStatus") or resource.get("loginApiProbeStatus") or "").lower()
                authenticated = (
                    state == "可用"
                    and login_status in {"logged-in", "已登录", "logged-in-api-ready"}
                    and api_status in {"logged-in-api-ready", "200", "ok", "已就绪"}
                )
                if not authenticated:
                    prepared = self.app.scheduler.store.transition(
                        raw,
                        STATE_PREFLIGHT,
                        stage="manual-intervention-result-check",
                        summary="登录窗口已提交，但页面、接口或资源状态未达到已登录标准。",
                        error_code="LOGIN_RESULT_NOT_CONFIRMED",
                        needs_manual=False,
                        next_action="检查慧策页面和接口状态后重新登录",
                    )
                    self.app.scheduler.store.transition(
                        prepared,
                        STATE_FAILED,
                        stage="manual-intervention-result-check",
                        summary="登录未确认成功，未写入成功状态。",
                        error_code="LOGIN_RESULT_NOT_CONFIRMED",
                        needs_manual=False,
                        next_action="返回资源详情重新检查或登录",
                    )
                    return
                prepared = self.app.scheduler.store.transition(
                    raw,
                    STATE_PREFLIGHT,
                    stage="manual-intervention-resume",
                    summary="人工输入/验证已完成，正在回查登录结果。",
                    error_code="",
                    needs_manual=False,
                    next_action="正在确认页面、接口和资源状态",
                )
                self.app.scheduler.store.transition(
                    prepared,
                    STATE_SUCCEEDED,
                    stage="manual-intervention-complete",
                    summary="正式登录已完成；页面、接口和资源状态已回查。",
                    error_code="",
                    needs_manual=False,
                    next_action="可继续使用当前资源",
                    extra={"result": self._uniform_resource_result(resource)},
                )
            else:
                resumed = self.app.scheduler.retry(task_id)
                self.tasks.wait(resumed, int(resumed.get("timeoutSeconds") or 90))
        except Exception as exc:
            print(f"原任务续接失败：{exc}")

    def _resource_from_task(
        self, resource: dict[str, Any], task: dict[str, Any] | None
    ) -> dict[str, Any]:
        if not isinstance(task, dict):
            return resource
        result = task.get("result")
        if not isinstance(result, dict):
            return resource
        source = dict(result)
        nested = source.get("resource")
        if isinstance(nested, dict):
            source.update(nested)
        if not any(key in source for key in ("connectionStatus", "loginStatus", "apiStatus", "checkedAt")):
            return resource
        checked = self.app.port_manager.sanitize_checked(
            source, base_resource=resource
        )
        return self.app.port_manager.merge_resource_state(resource, checked)

    @staticmethod
    def _uniform_resource_result(resource: dict[str, Any]) -> dict[str, Any]:
        """Keep resumed task results aligned with the public resource contract."""
        return {
            "resource": resource,
            "connectionStatus": resource.get("connectionStatus"),
            "pageStatus": resource.get("pageStatus") or resource.get("pageMatchStatus"),
            "loginStatus": resource.get("loginStatus"),
            "apiStatus": resource.get("apiStatus") or resource.get("loginApiProbeStatus"),
            "confidence": resource.get("confidence") or resource.get("loginConfidence"),
            "checkedAt": resource.get("checkedAt") or resource.get("loginCheckedAt"),
            "nextAction": resource.get("nextAction"),
        }

    @staticmethod
    def _print_list(resources: list[dict[str, Any]]) -> None:
        for index, item in enumerate(resources, 1):
            print(
                f"   连接：{item.get('connectionStatus') or '未检查'} / "
                f"页面：{item.get('pageStatus') or '未检查'} / "
                f"登录：{item.get('loginStatus') or '未检查'} / "
                f"API：{item.get('apiStatus') or '未检查'} / "
                f"时间：{item.get('checkedAt') or item.get('snapshotAt') or '无'} / "
                f"新鲜度：{item.get('freshness') or 'never-checked'}"
            )
            state = item.get("state") or "未验证"
            name = item.get("name") or item.get("resourceName") or "未命名资源"
            enabled = "启用" if item.get("enabled", True) else "停用"
            print(f"{index}. {name} / 端口 {item.get('port')} / {enabled}：{state}（{item.get('freshness') or '未验证'}）")
            print(
                f"   {item.get('summary')}；下一步："
                f"{STATE_HINTS.get(str(state), '请先检查状态')}"
            )

    @staticmethod
    def _print_detail(resource: dict[str, Any]) -> None:
        print("\n资源详情")
        print(
            f"连接：{resource.get('connectionStatus') or '未检查'}；"
            f"浏览器：{resource.get('browserStatus') or '未检查'}；"
            f"页面：{resource.get('pageStatus') or '未检查'}；"
            f"登录：{resource.get('loginStatus') or '未检查'}；"
            f"API：{resource.get('apiStatus') or '未检查'}"
        )
        print(
            f"检查时间：{resource.get('checkedAt') or '无'}；"
            f"快照时间：{resource.get('snapshotAt') or '无'}；"
            f"新鲜度：{resource.get('freshness') or 'never-checked'}；"
            f"来源：{resource.get('statusSource') or 'PortManager 公共 JSON'}；"
            f"下一步：{resource.get('nextActionLabel') or resource.get('nextAction') or '查看资源状态'}"
        )
        print(f"名称：{resource.get('name') or resource.get('resourceName') or '未命名'}")
        print(f"平台：{resource.get('platform') or resource.get('platformName') or '未标明'}")
        print(f"端口：{resource.get('port')}")
        print(f"当前状态：{resource.get('state') or '未验证'}")
        print(f"端口连接：{resource.get('connectionStatus') or '未检查'}")
        print(f"登录状态：{resource.get('loginStatus') or '状态未知'}")
        print(f"只读接口：{resource.get('apiStatus') or '未检查'}")
        print(f"最近检查：{resource.get('checkedAt') or '尚未检查'}")
        print(f"状态新鲜度：{resource.get('freshness') or '未验证'}")
        print(f"状态来源：{resource.get('statusSource') or '尚未进行真实检查'}")
        print(f"异步检测：{resource.get('watcherState') or '按需真实检查'}")
        print("人工介入：如页面要求验证码或外部风控，当前任务会停在等待验证并提供继续/取消入口。")
        if resource.get("interventionStatus") == "waiting-external-verification":
            print("当前等待：外部安全验证；完成后在当前提示输入‘继续’，或输入‘取消’。")
        print(f"下一步：{STATE_HINTS.get(str(resource.get('state')), '请先检查状态')}")

    @staticmethod
    def _resource_label(resource: dict[str, Any]) -> str:
        name = resource.get("name") or resource.get("resourceName") or "未命名资源"
        return f"{name}（端口 {resource.get('port') or '未知'}）"
