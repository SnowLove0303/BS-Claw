from __future__ import annotations

from typing import Any


class ResourceSelector:
    """Shared user-facing selector backed only by PortManager public JSON."""

    def __init__(self, application: Any, io: Any) -> None:
        self.app = application
        self.io = io

    def select(self, mode: str = "single") -> dict[str, Any] | list[dict[str, Any]] | None:
        if mode not in {"single", "multi", "all"}:
            raise ValueError(f"unsupported resource selection mode: {mode}")
        selected_indexes: set[int] = set()
        while True:
            result = self.app.port_manager.list_resources(force_refresh=True)
            if not result.success or not isinstance(result.data, list):
                self.io.failure(
                    result.message or "无法读取资源列表。",
                    result.error_code or "RESOURCE_LIST_FAILED",
                    "检查端口管理服务后重试。",
                )
                return None
            resources = [item for item in result.data if isinstance(item, dict) and item.get("resourceId")]
            if not resources:
                print("当前没有可选资源。请先进入资源管理注册资源。")
                return None
            if mode == "all":
                self._print_resources(resources, selected_indexes)
                print("A. 全选当前列表   R. 刷新列表   0. 返回")
                choice = self.io.input("请选择").strip().lower()
                if choice == "r":
                    continue
                if choice == "0":
                    return None
                if choice == "a":
                    return list(resources)
                print("请选择 A 全选、R 刷新或 0 返回。")
                continue
            if mode == "multi":
                selected_indexes = self._select_multi(resources, selected_indexes)
                if selected_indexes:
                    return [resources[index] for index in sorted(selected_indexes)]
                return None
            self._print_resources(resources, selected_indexes)
            print("R. 刷新列表   0. 返回")
            choice = self.io.input("请输入资源序号").strip().lower()
            if choice == "r":
                continue
            if choice == "0":
                return None
            try:
                return resources[int(choice) - 1]
            except (ValueError, IndexError):
                print("请输入列表中的有效序号。")

    def _select_multi(
        self, resources: list[dict[str, Any]], selected_indexes: set[int]
    ) -> set[int]:
        while True:
            self._print_resources(resources, selected_indexes)
            print("输入序号可选择或取消；可用逗号一次输入多个序号。")
            print("A. 全选   C. 确认选择   R. 刷新列表   0. 返回")
            choice = self.io.input("请选择").strip().lower()
            if choice == "0":
                return set()
            if choice == "r":
                return selected_indexes
            if choice == "a":
                selected_indexes = set(range(len(resources)))
                continue
            if choice == "c":
                if not selected_indexes:
                    print("请至少选择一个资源，或输入 0 返回。")
                    continue
                return selected_indexes
            indexes = self._parse_indexes(choice, len(resources))
            if indexes is None:
                print("请输入列表中的有效序号，多个序号用逗号分隔。")
                continue
            for index in indexes:
                if index in selected_indexes:
                    selected_indexes.remove(index)
                else:
                    selected_indexes.add(index)

    @staticmethod
    def _parse_indexes(value: str, size: int) -> list[int] | None:
        try:
            indexes = [int(part.strip()) - 1 for part in value.split(",") if part.strip()]
        except ValueError:
            return None
        if not indexes or any(index < 0 or index >= size for index in indexes):
            return None
        return list(dict.fromkeys(indexes))

    @staticmethod
    def _print_resources(resources: list[dict[str, Any]], selected_indexes: set[int]) -> None:
        print("\n请选择资源：")
        for index, item in enumerate(resources, 1):
            mark = "[已选] " if index - 1 in selected_indexes else ""
            name = item.get("resourceName") or item.get("name") or "未命名资源"
            port = item.get("port") or "未知"
            state = item.get("state") or item.get("loginStatus") or item.get("connectionStatus") or "未检查"
            checked = item.get("checkedAt") or item.get("snapshotAt") or "未检查"
            connection = item.get("connectionStatus") or "未检查"
            page = item.get("pageStatus") or "未检查"
            login = item.get("loginStatus") or "状态未知"
            api = item.get("apiStatus") or "未检查"
            freshness = item.get("freshness") or item.get("checkFreshness") or "未检查"
            next_action = item.get("nextActionLabel") or item.get("nextAction") or "按状态提示处理"
            print(
                f"{index}. {mark}{name} / 端口 {port} / {state} / "
                f"连接 {connection} / 页面 {page} / 登录 {login} / API {api} / "
                f"更新时间 {checked} / 新鲜度 {freshness} / 下一步 {next_action}"
            )
