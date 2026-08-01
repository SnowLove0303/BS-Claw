from __future__ import annotations

from typing import Any

from .module_registry import ModuleRegistry
from .port_manager import PortManagerAdapter
from .scheduler_execution import SchedulerExecution
from .scheduler_recovery import SchedulerRecovery
from .scheduler_store import SchedulerStore
from .scheduler_view import public_task


class UnifiedScheduler:
    """Public task-lifecycle facade.

    Preflight, execution, verification and recovery live in dedicated
    collaborators so this class remains the stable adapter-facing contract.
    """

    def __init__(
        self,
        store: SchedulerStore,
        registry: ModuleRegistry,
        port_manager: PortManagerAdapter,
    ) -> None:
        self.store = store
        self.execution = SchedulerExecution(store, registry, port_manager)
        self.recovery = SchedulerRecovery(store, self.execution.start)

    def submit(
        self,
        *,
        module_id: str,
        action: str,
        parameters: dict[str, Any],
        resource_id: str,
        timeout_seconds: int,
    ) -> dict[str, Any]:
        task = self.store.create(
            module_id=module_id,
            action=action,
            parameters=parameters,
            resource_id=resource_id,
            timeout_seconds=timeout_seconds,
        )
        return self.execution.start(task)

    def status(self, task_id: str) -> dict[str, Any]:
        return public_task(self.store.load(task_id), include_result=False)

    def result(self, task_id: str) -> dict[str, Any]:
        return public_task(self.store.load(task_id), include_result=True)

    def list(self, limit: int) -> list[dict[str, Any]]:
        return [public_task(item, include_result=False) for item in self.store.list(limit)]

    def cancel(self, task_id: str) -> dict[str, Any]:
        return self.recovery.cancel(task_id)

    def retry(self, task_id: str) -> dict[str, Any]:
        return self.recovery.retry(task_id)

    def recover(self) -> list[dict[str, Any]]:
        return self.recovery.recover()

    def run_worker(self, task_id: str) -> dict[str, Any]:
        return self.execution.run_worker(task_id)
