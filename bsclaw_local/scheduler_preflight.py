from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .capabilities import (
    WRITE_LEVEL_BUSINESS,
    WRITE_LEVEL_SERVICE_STATE,
    action_write_level,
)
from .module_registry import ModuleRegistry, RegisteredModule
from .port_manager import PortManagerAdapter
from .resource_snapshot import project_resource
from .resource_snapshot import project_resource
from .scheduler_failures import finish_blocked
from .scheduler_models import (
    STATE_BLOCKED,
    STATE_WAITING_EXTERNAL_VERIFICATION,
    STATE_WAITING_LOGIN,
    STATE_WAITING_MANUAL,
    STATE_WAITING_RESOURCE,
)
from .scheduler_store import SchedulerStore
from .scheduler_view import public_task


@dataclass(frozen=True)
class PreflightResult:
    task: dict[str, Any]
    module: RegisteredModule | None = None
    action: dict[str, Any] | None = None
    timeout_seconds: int = 0
    terminal: dict[str, Any] | None = None


class SchedulerPreflight:
    def __init__(
        self,
        store: SchedulerStore,
        registry: ModuleRegistry,
        port_manager: PortManagerAdapter,
    ) -> None:
        self.store = store
        self.registry = registry
        self.port_manager = port_manager

    def evaluate(self, task: dict[str, Any]) -> PreflightResult:
        module = self.registry.find(str(task["moduleId"]))
        if module is None:
            return self._blocked(task, "MODULE_NOT_FOUND", "未发现正式注册模块", "配置真实模块目录和 manifest 后执行 task retry", True)
        if not module.valid:
            return self._blocked(task, "MODULE_MANIFEST_INVALID", "模块 manifest 不符合统一契约", "修复 manifest 后执行 task retry", True)
        if not self.registry.entry_path(module).is_file():
            return self._blocked(task, "MODULE_ENTRY_NOT_FOUND", "模块执行入口不存在", "补齐真实执行入口后执行 task retry", True)
        action = self.registry.action(module, str(task["action"]))
        if action is None:
            return self._blocked(task, "ACTION_NOT_SUPPORTED", "模块不支持该动作", "查看 modules 输出中的 supportedActions", False)

        task["moduleVersion"] = module.manifest.get("version")
        write_level = action_write_level(action)
        task["writeLevel"] = write_level
        task["serviceStateWritesDeclared"] = write_level == WRITE_LEVEL_SERVICE_STATE
        task["businessWritesDeclared"] = write_level == WRITE_LEVEL_BUSINESS
        if task["businessWritesDeclared"] and not self._business_write_authorized(task, action):
            return self._blocked(task, "BUSINESS_WRITE_NOT_ENABLED", "本阶段禁止执行业务写入任务", "等待后续确认、幂等、锁和回查契约完成", False)
        if bool(action.get("requiresHuiceResource")):
            gate = self._login_gate(task)
            if gate is not None:
                return PreflightResult(task=task, terminal=gate)
        selection_mode = str(action.get("resourceSelectionMode") or "none")
        execution_policy = str(action.get("resourceExecutionPolicy") or "policy-pending")
        if selection_mode in {"single", "multi", "all"} and execution_policy == "policy-pending":
            return self._blocked(task, "RESOURCE_POLICY_PENDING", "璧勬簮鎵ц绛栫暐鏈槑纭€佸凡闃绘柇鎻愪氦", "鍏堝畾涔夎祫婧愰€夋嫨妯″紡涓庡崰鐢ㄧ瓥鐣ヨ缃悗閲嶈瘯", False)
        if str(action.get("resourcePolicy") or "") != "none" and execution_policy == "policy-pending":
            return self._blocked(task, "RESOURCE_POLICY_PENDING", "资源多任务执行策略尚未确认", "等待用户确认同端口/跨端口并发与锁粒度后再执行", False)
        timeout_seconds = min(
            int(task.get("timeoutSeconds") or 60),
            int(action.get("timeoutSeconds") or 60),
        )
        return PreflightResult(task, module, action, timeout_seconds)

    @staticmethod
    def _business_write_authorized(task: dict[str, Any], action: dict[str, Any]) -> bool:
        gate = action.get("businessWriteGate")
        if not isinstance(gate, dict) or gate.get("allowWhenSchedulerAuthorized") is not True:
            return False
        params = task.get("parameters")
        if not isinstance(params, dict):
            return False
        authorization = params.get("writeAuthorization")
        if not isinstance(authorization, dict):
            return False
        if str(authorization.get("scope") or "") != str(gate.get("requiredScope") or "isolated-resource"):
            return False
        if str(authorization.get("status") or "") != "approved":
            return False
        if gate.get("requiresReadback") is True and not isinstance(params.get("readbackRequest"), dict):
            return False
        return True

    def _blocked(
        self,
        task: dict[str, Any],
        error_code: str,
        summary: str,
        next_action: str,
        retryable: bool,
    ) -> PreflightResult:
        terminal = finish_blocked(
            self.store, task, error_code, summary, next_action, retryable=retryable
        )
        return PreflightResult(task=task, terminal=terminal)

    def _login_gate(self, task: dict[str, Any]) -> dict[str, Any] | None:
        resource_id = str(task.get("resourceId") or "")
        if not resource_id:
            task = self.store.transition(
                task, STATE_WAITING_RESOURCE, stage="resource-selection",
                summary="任务需要慧策资源，但当前还没有选择资源",
                error_code="RESOURCE_SELECTION_REQUIRED", needs_manual=False,
                next_action="返回资源选择页面，选择一个可用的慧策资源后再继续", retryable=False,
            )
            return public_task(task, include_result=True)
        result = self.port_manager.check_resource(resource_id)
        if not result.success or not isinstance(result.data, dict):
            code = result.error_code or "RESOURCE_CHECK_FAILED"
            state = STATE_WAITING_LOGIN if code in {"login-required", "LOGIN_REQUIRED", "SESSION_EXPIRED"} else STATE_BLOCKED
            task = self.store.transition(
                task, state, stage="login-gate", summary=result.message or "资源实时检查未通过",
                error_code=code, needs_manual=state in {STATE_WAITING_LOGIN, STATE_WAITING_EXTERNAL_VERIFICATION},
                next_action=("使用正式 Login 入口完成登录后执行 task retry" if state == STATE_WAITING_LOGIN else "修复端口、浏览器或页面状态后执行 task retry"),
                retryable=state == STATE_BLOCKED,
                extra={"result": project_resource({"resourceId": resource_id, **(result.data if isinstance(result.data, dict) else {})})},
            )
            return public_task(task, include_result=True)
        resource = self.port_manager.sanitize_checked(result.data)
        if resource.get("state") != "可用":
            state = STATE_WAITING_LOGIN if resource.get("state") == "需登录" else STATE_BLOCKED
            task = self.store.transition(
                task, state, stage="login-gate", summary=resource["summary"],
                error_code="LOGIN_REQUIRED" if state == STATE_WAITING_LOGIN else "LOGIN_STATE_NOT_READY",
                needs_manual=state == STATE_WAITING_LOGIN,
                next_action="先通过端口管理执行实时 Check/Login", retryable=state == STATE_BLOCKED,
                extra={"result": project_resource({"resourceId": resource_id, **resource})},
            )
            return public_task(task, include_result=True)
        task["resourceEvidence"] = {
            key: resource[key]
            for key in ("resourceId", "resourceName", "port", "enabled", "connectionStatus", "browserStatus", "pageStatus", "loginStatus", "apiStatus", "confidence", "checkedAt", "snapshotAt", "freshness", "statusSource", "nextAction", "occupancy", "lease")
        }
        return None
