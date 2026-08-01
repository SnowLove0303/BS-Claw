from __future__ import annotations

from typing import Any

from .module_registry import ModuleRegistry
from .paths import ProjectPaths


class ModuleDiscovery:
    """Backward-compatible facade over the formal module registry."""

    def __init__(self, paths: ProjectPaths) -> None:
        self.registry = ModuleRegistry(paths)

    def discover(self, service_snapshot: dict[str, Any]) -> list[dict[str, Any]]:
        del service_snapshot
        return self.registry.describe()
