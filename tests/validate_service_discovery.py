from __future__ import annotations

import sys
import os
from pathlib import Path


LOCAL_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(LOCAL_ROOT))

from bsclaw_local.module_registry import ModuleRegistry
from bsclaw_local.paths import ProjectPaths
from bsclaw_local.capabilities import CapabilityCatalog


def main() -> int:
    isolated = LOCAL_ROOT / "data" / "scheduler" / "discovery-validation"
    empty_local = isolated / "empty-local"
    empty_repository = isolated / "empty-repository"
    no_manifest = empty_local / "services" / "directory-without-manifest"
    no_manifest.mkdir(parents=True, exist_ok=True)
    empty_repository.mkdir(parents=True, exist_ok=True)
    empty_paths = ProjectPaths(
        local_root=empty_local,
        repository_root=empty_repository,
        port_manager_root=empty_repository / "PortManager-Phase1",
        huice_login_agent_root=empty_repository / "HuiceLoginAgent",
        data_root=empty_local / "data",
    )
    previous = os.environ.get("BSCLAW_SERVICE_ROOTS")
    try:
        os.environ.pop("BSCLAW_SERVICE_ROOTS", None)
        empty_modules, empty_docs = ModuleRegistry(empty_paths).scan()
        if empty_modules or empty_docs:
            raise AssertionError("没有 manifest 的目录不得注册为服务")

        os.environ["BSCLAW_SERVICE_ROOTS"] = str(
            LOCAL_ROOT / "services" / "port-manager"
        )
        explicit = ModuleRegistry(empty_paths).find("port-manager")
        if explicit is None or not explicit.valid:
            raise AssertionError("BSCLAW_SERVICE_ROOTS 显式服务目录未被发现")
    finally:
        if previous is None:
            os.environ.pop("BSCLAW_SERVICE_ROOTS", None)
        else:
            os.environ["BSCLAW_SERVICE_ROOTS"] = previous

    real_paths = ProjectPaths.discover()
    real_registry = ModuleRegistry(real_paths)
    service = real_registry.find("port-manager")
    if service is None or not service.valid:
        raise AssertionError("PortManager 正式服务 manifest 未被发现")
    if service.manifest.get("type") != "resource-service":
        raise AssertionError("PortManager 类型不是 resource-service")
    capabilities = CapabilityCatalog(real_registry).all()
    check = next(
        (item for item in capabilities if item.capability_id == "check-resource"),
        None,
    )
    if check is None or check.write_level != "service-state-write":
        raise AssertionError("资源检查未声明 service-state-write 用户能力")
    if not any(item.capability_id == "storage-plan" for item in capabilities):
        raise AssertionError("存储盘点用户能力缺失")
    print(
        "SERVICE_DISCOVERY_OK empty=0 noManifest=ignored "
        "explicit=registered sibling=registered"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
