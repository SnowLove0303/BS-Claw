from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


class PathConfigurationError(RuntimeError):
    pass


def _is_f_drive(path: Path) -> bool:
    return path.drive.upper() == "F:"


def _resolve_override(name: str, default: Path) -> Path:
    raw = os.environ.get(name)
    candidate = Path(raw).expanduser() if raw else default
    resolved = candidate.resolve(strict=False)
    if not _is_f_drive(resolved):
        raise PathConfigurationError(f"{name or '项目路径'} 必须位于 F 盘。")
    return resolved


@dataclass(frozen=True)
class ProjectPaths:
    local_root: Path
    repository_root: Path
    port_manager_root: Path
    huice_login_agent_root: Path
    data_root: Path

    @classmethod
    def discover(cls) -> "ProjectPaths":
        local_root = Path(__file__).resolve().parent.parent
        if not _is_f_drive(local_root):
            raise PathConfigurationError("BS Claw 本地层必须位于 F 盘。")
        repository_root = local_root.parent
        return cls(
            local_root=local_root,
            repository_root=repository_root,
            port_manager_root=_resolve_override(
                "BSCLAW_PORT_MANAGER_ROOT",
                repository_root / "PortManager-Phase1",
            ),
            huice_login_agent_root=_resolve_override(
                "BSCLAW_HUICE_LOGIN_AGENT_ROOT",
                repository_root / "HuiceLoginAgent",
            ),
            data_root=_resolve_override("BSCLAW_DATA_ROOT", local_root / "data"),
        )

    @property
    def port_manager_entry(self) -> Path:
        return self.port_manager_root / "port-manager.ps1"

    @property
    def huice_entry(self) -> Path:
        return self.huice_login_agent_root / "login-agent.ps1"

    @property
    def manifest_path(self) -> Path:
        return self.local_root / "local.manifest.json"

    @property
    def scheduler_root(self) -> Path:
        return self.data_root / "scheduler"
