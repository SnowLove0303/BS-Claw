from __future__ import annotations

import json
import subprocess
from datetime import datetime, timedelta
import time
from typing import Any

from .models import CommandResult, now_iso
from .paths import ProjectPaths
from .process_runner import run_powershell_interactive, run_powershell_json
from .resource_snapshot import project_resource, project_resources


FRESHNESS_SECONDS = 900
RESOURCE_CACHE_SECONDS = 8


def _text(value: Any) -> str:
    return str(value or "").strip()


def _parse_time(value: Any) -> datetime | None:
    raw = _text(value)
    if not raw:
        return None
    try:
        return datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def _is_fresh(value: Any) -> bool:
    checked = _parse_time(value)
    if checked is None or checked.tzinfo is None:
        return False
    age = datetime.now().astimezone() - checked.astimezone()
    return -timedelta(minutes=5) <= age <= timedelta(seconds=FRESHNESS_SECONDS)


def _state_for(resource: dict[str, Any], last: dict[str, Any]) -> tuple[str, str]:
    if not bool(resource.get("enabled", True)):
        return "不可用", "资源已停用"
    login = _text(last.get("loginStatus")).lower()
    api = _text(last.get("loginApiProbeStatus")).lower()
    confidence = _text(last.get("loginConfidence")).lower()
    fresh = _is_fresh(last.get("loginCheckedAt") or last.get("lastCheckedAt"))
    if login in {"login-required", "未登录", "需要登录", "登录已过期", "session-expired"}:
        return "需登录", "慧策会话需要登录"
    if login in {"已登录", "logged-in", "authenticated"} and api == "logged-in-api-ready":
        if confidence == "high" and fresh:
            return "可用", "登录和只读接口状态有效"
        return "未验证", "已有登录记录，但需要重新检查状态新鲜度"
    if _text(last.get("loginDetectionErrorCode")) or _text(last.get("watcherErrorCode")):
        return "需修复", "状态维护链路存在异常"
    return "未验证", "尚无足够的实时登录证据"


class PortManagerAdapter:
    def __init__(self, paths: ProjectPaths) -> None:
        self.paths = paths
        self._resource_cache: list[dict[str, Any]] | None = None
        self._resource_cache_at = 0.0
        self._last_list_elapsed_ms = 0
        self._cache_source = "未读取"
        self._snapshot_at = ""

    @property
    def snapshot_path(self):
        return self.paths.data_root / "port-state-snapshot.json"

    def _load_snapshot(self) -> list[dict[str, Any]]:
        try:
            payload = json.loads(self.snapshot_path.read_text(encoding="utf-8"))
            items = payload.get("resources") if isinstance(payload, dict) else None
            if not isinstance(items, list):
                return []
            self._snapshot_at = str(payload.get("capturedAt") or "")
            return project_resources(
                [item for item in items if isinstance(item, dict)],
                snapshot_at=self._snapshot_at,
            )
        except (OSError, ValueError):
            return []

    def _save_snapshot(self, resources: list[dict[str, Any]], elapsed_ms: int) -> None:
        try:
            self.paths.data_root.mkdir(parents=True, exist_ok=True)
            captured = now_iso()
            self.snapshot_path.write_text(
                json.dumps(
                    {"capturedAt": captured, "source": "PortManager List", "elapsedMs": elapsed_ms, "resources": resources},
                    ensure_ascii=False,
                    indent=2,
                ),
                encoding="utf-8",
            )
            self._snapshot_at = captured
        except OSError:
            pass

    def invalidate_cache(self) -> None:
        self._resource_cache = None
        self._resource_cache_at = 0.0

    @property
    def last_list_elapsed_ms(self) -> int:
        return self._last_list_elapsed_ms

    def list_resources(self, *, force_refresh: bool = False) -> CommandResult:
        now = time.monotonic()
        if not force_refresh and self._resource_cache is not None and now - self._resource_cache_at <= RESOURCE_CACHE_SECONDS:
            return CommandResult(True, list(self._resource_cache), "复用本地端口状态缓存。", "", 0)
        if not force_refresh and self._resource_cache is None:
            snapshot = self._load_snapshot()
            if snapshot:
                self._resource_cache = snapshot
                self._resource_cache_at = now
                self._cache_source = "BSClaw 本地事实快照"
                return CommandResult(True, list(snapshot), "已读取最近端口状态快照；后台检测会继续刷新。", "", 0)
        result = run_powershell_json(
            self.paths.port_manager_entry,
            ["-Action", "List", "-OutputFormat", "Json", "-NonInteractive"],
        )
        if not result.success:
            return result
        raw_resources = result.data if isinstance(result.data, list) else []
        captured_at = now_iso()
        previous = {
            str(item.get("resourceId")): item
            for item in (self._resource_cache or self._load_snapshot())
            if isinstance(item, dict) and item.get("resourceId")
        }
        listed: list[dict[str, Any]] = []
        for raw in raw_resources:
            if not isinstance(raw, dict):
                continue
            item = self._sanitize(raw)
            prior = previous.get(str(item.get("resourceId") or ""))
            if isinstance(prior, dict):
                # PortManager List is the source for definitions; retain the
                # newest public Check projection when List omits LastStatus.
                for key in (
                    "connectionStatus", "browserStatus", "pageStatus",
                    "loginStatus", "apiStatus", "confidence", "checkedAt",
                    "freshness", "checkFreshness", "statusSource", "lastStatus",
                    "occupancy", "lease", "state", "summary", "nextAction",
                    "nextActionLabel",
                ):
                    if not item.get(key) or item.get(key) in {"未检查", "状态未知", "unknown"}:
                        if prior.get(key) not in (None, ""):
                            item[key] = prior[key]
            listed.append(item)
        resources = project_resources(listed, snapshot_at=captured_at)
        self._resource_cache = resources
        self._resource_cache_at = time.monotonic()
        self._last_list_elapsed_ms = result.elapsed_ms
        self._cache_source = "PortManager List"
        self._save_snapshot(resources, result.elapsed_ms)
        return CommandResult(True, list(resources), f"读取到 {len(resources)} 个端口资源。", "", result.elapsed_ms)

    def service_status(self, *, force_refresh: bool = False) -> dict[str, Any]:
        result = self.list_resources(force_refresh=force_refresh)
        if not result.success:
            return {
                "state": "不可用",
                "summary": result.message or "端口管理不可用",
                "resourceCount": 0,
                "errorCode": result.error_code or "PORT_MANAGER_UNAVAILABLE",
                "resources": [],
                "timingMs": result.elapsed_ms,
            }
        resources = result.data
        return {
            "state": "可用",
            "summary": f"端口管理可用，共 {len(resources)} 个资源",
            "resourceCount": len(resources),
            "errorCode": None,
            "resources": resources,
            "timingMs": result.elapsed_ms,
            "cacheAgeSeconds": round(max(0.0, time.monotonic() - self._resource_cache_at), 1),
            "source": self._cache_source,
            "snapshotAt": self._snapshot_at or None,
            "freshness": "最近检查有效" if self._snapshot_at and _is_fresh(self._snapshot_at) else "已过期",
        }

    def check_resource(self, resource_id: str) -> CommandResult:
        previous = list(self._resource_cache or self._load_snapshot())
        self.invalidate_cache()
        result = run_powershell_json(
            self.paths.port_manager_entry,
            [
                "-Action",
                "Check",
                "-ResourceId",
                resource_id,
                "-OutputFormat",
                "Json",
                "-NonInteractive",
            ],
            timeout_seconds=90,
        )
        if result.success and isinstance(result.data, dict):
            checked = self.sanitize_checked(result.data)
            current = previous
            replaced = False
            for index, item in enumerate(current):
                if str(item.get("resourceId") or "") == str(resource_id):
                    current[index] = self.merge_resource_state(item, checked)
                    replaced = True
                    break
            if not replaced and checked.get("resourceId"):
                current.append(checked)
            if replaced or checked.get("resourceId"):
                self._resource_cache = project_resources(current, snapshot_at=now_iso())
                self._resource_cache_at = time.monotonic()
                self._cache_source = "PortManager public JSON Check"
                self._save_snapshot(self._resource_cache, result.elapsed_ms)
        return result

    def public_action(
        self,
        action: str,
        *,
        resource_id: str = "",
        timeout_seconds: int = 90,
        arguments: dict[str, Any] | None = None,
    ) -> CommandResult:
        """Call only the PortManager PowerShell public contract.

        The unified layer never imports PortManager modules or reads its SQLite;
        this is the single adapter seam for resource lifecycle operations.
        """
        args: list[str] = ["-Action", action]
        values = arguments or {}
        mapping = {
            "resourceId": "-ResourceId", "resourceName": "-ResourceName",
            "platformName": "-PlatformName", "hostName": "-HostName",
            "port": "-Port", "connectionMode": "-ConnectionMode",
            "browserExecutable": "-BrowserExecutable",
            "browserProfileDirectory": "-BrowserProfileDirectory",
            "startUrl": "-StartUrl", "platformUrlPatterns": "-PlatformUrlPatterns",
            "loginPagePatterns": "-LoginPagePatterns", "notes": "-Notes",
            "confirmationText": "-ConfirmationText", "leaseId": "-LeaseId",
            "taskRef": "-TaskRef", "leaseDurationSeconds": "-LeaseDurationSeconds",
        }
        if resource_id:
            values = {**values, "resourceId": resource_id}
        for key, flag in mapping.items():
            value = values.get(key)
            if value in (None, ""):
                continue
            args.extend([flag, str(value)])
        if values.get("disabled") is True:
            args.append("-Disabled")
        args.extend(["-OutputFormat", "Json", "-NonInteractive"])
        result = run_powershell_json(
            self.paths.port_manager_entry, args, timeout_seconds=timeout_seconds
        )
        if action in {"List", "Register", "Edit", "Enable", "Disable", "Delete", "Check", "CheckAll"}:
            self.invalidate_cache()
        return result

    def occupancy(self, resource_id: str) -> CommandResult:
        return self.public_action("Occupancy", resource_id=resource_id)

    def acquire_lease(
        self, resource_id: str, *, task_ref: str, duration_seconds: int = 900
    ) -> CommandResult:
        return self.public_action(
            "AcquireLease",
            resource_id=resource_id,
            timeout_seconds=45,
            arguments={
                "taskRef": task_ref,
                "leaseDurationSeconds": duration_seconds,
            },
        )

    def release_lease(self, lease_id: str) -> CommandResult:
        return self.public_action(
            "ReleaseLease",
            timeout_seconds=45,
            arguments={"leaseId": lease_id},
        )

    def login_check(self, resource_id: str) -> CommandResult:
        return self.public_action("LoginCheck", resource_id=resource_id, timeout_seconds=45)

    def cancel_login_check(self, resource_id: str) -> CommandResult:
        return self.public_action("CancelLoginCheck", resource_id=resource_id, timeout_seconds=45)

    def check_all(self) -> CommandResult:
        return self.public_action("CheckAll", timeout_seconds=180)

    def open_resource(self, resource_id: str) -> CommandResult:
        return run_powershell_json(
            self.paths.port_manager_entry,
            [
                "-Action",
                "Open",
                "-ResourceId",
                resource_id,
                "-TimeoutSeconds",
                "20",
                "-OutputFormat",
                "Json",
                "-NonInteractive",
            ],
            timeout_seconds=45,
        )

    def login_resource_interactive(self, resource_id: str) -> int:
        return run_powershell_interactive(
            self.paths.port_manager_entry,
            ["-Action", "HuiceLogin", "-ResourceId", resource_id],
        )

    def login_resource_with_credentials(self, resource_id: str, values: dict[str, str]) -> dict[str, Any]:
        """Run the existing Huice HTTP login and return a sanitized contract."""
        command = [
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(self.paths.huice_entry), "-Action", "Login", "-ResourceId", resource_id,
            "-ConfirmServiceAgreement", "-OutputFormat", "Json",
        ]
        payload = "\n".join((values.get("tenant", ""), values.get("account", ""), values.get("password", ""))) + "\n"
        try:
            completed = subprocess.run(
                command,
                input=payload,
                text=True,
                encoding="utf-8",
                errors="replace",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=300,
                check=False,
            )
            parsed: dict[str, Any] | None = None
            decoder = json.JSONDecoder()
            for index, char in enumerate(completed.stdout):
                if char != "{":
                    continue
                try:
                    candidate, _ = decoder.raw_decode(completed.stdout[index:])
                except json.JSONDecodeError:
                    continue
                if isinstance(candidate, dict) and ("success" in candidate or "status" in candidate):
                    parsed = candidate
                    break
            if parsed is not None:
                parsed_data = parsed.get("data") if isinstance(parsed.get("data"), dict) else {}
                result_status = parsed.get("message") or parsed.get("status") or parsed_data.get("status") or ""
                return {
                    "success": bool(parsed.get("success")) and str(result_status).lower() in {
                        "logged-in-api-ready", "success", "成功", "已登录"
                    },
                    "status": result_status,
                    "errorCode": parsed.get("errorCode") or "",
                    "message": parsed.get("message") or parsed.get("summary") or "登录结果已返回",
                    "data": parsed_data,
                    "exitCode": int(completed.returncode),
                }
            text = (completed.stdout + "\n" + completed.stderr).lower()
            if "captcha" in text or "verification" in text or "验证码" in text or "风控" in text:
                error_code = "EXTERNAL_VERIFICATION_REQUIRED"
            elif "invalid" in text or "账号或密码" in text or "credential" in text:
                error_code = "INVALID_CREDENTIALS"
            elif "cdp" in text:
                error_code = "CDP_ERROR"
            else:
                error_code = "LOGIN_RESULT_UNPARSEABLE"
            return {
                "success": False,
                "status": "failed",
                "errorCode": error_code,
                "message": "登录适配器未返回可确认的正式结果",
                "data": {},
                "exitCode": int(completed.returncode),
            }
        except subprocess.TimeoutExpired:
            return {
                "success": False,
                "status": "timeout",
                "errorCode": "LOGIN_PROCESS_TIMEOUT",
                "message": "登录进程超时，未确认页面/API/资源状态",
                "data": {},
                "exitCode": None,
            }
        finally:
            payload = "\n" * len(payload)

    def open_menu(self) -> int:
        return run_powershell_interactive(
            self.paths.port_manager_entry,
            ["-Action", "Menu"],
        )

    @staticmethod
    def _sanitize(resource: dict[str, Any]) -> dict[str, Any]:
        last = resource.get("lastStatus")
        last_status = last if isinstance(last, dict) else {}
        state, summary = _state_for(resource, last_status)
        checked_at = _text(
            last_status.get("loginCheckedAt") or last_status.get("lastCheckedAt")
        )
        checked = _parse_time(checked_at)
        age_seconds = None
        freshness = "从未检测"
        if checked is not None and checked.tzinfo is not None:
            age_seconds = max(0, int((datetime.now().astimezone() - checked.astimezone()).total_seconds()))
            freshness = "最近检查有效" if age_seconds <= FRESHNESS_SECONDS else "已过期"
        watcher_state = "后台检测未运行，按需真实检查"
        monitor_freshness = "后台未运行"
        if last_status.get("watcherPid") and last_status.get("watcherHeartbeatAt"):
            watcher_state = "后台检测记录存在，状态以最近真实检查为准"
            monitor_freshness = "后台检测已记录"
        return {
            "resourceId": _text(resource.get("resourceId")),
            "name": _text(resource.get("resourceName") or resource.get("platformName")),
            "platform": _text(resource.get("platformName") or resource.get("platformId")),
            "port": resource.get("port"),
            "enabled": bool(resource.get("enabled", True)),
            "state": state,
            "summary": summary,
            "connectionStatus": _text(last_status.get("connectionStatus")) or "未检查",
            "loginStatus": _text(last_status.get("loginStatus")) or "状态未知",
            "apiStatus": _text(last_status.get("loginApiProbeStatus")) or "未检查",
            "confidence": _text(last_status.get("loginConfidence")) or "unknown",
            "checkedAt": checked_at or None,
            "fresh": _is_fresh(checked_at),
            "freshness": freshness,
            "checkFreshness": freshness,
            "monitorFreshness": monitor_freshness,
            "ageSeconds": age_seconds,
            "statusSource": "PortManager 最近一次真实检查" if checked_at else "尚未进行真实检查",
            "watcherState": watcher_state,
            "needsCheck": state in {"未验证", "需修复"},
        }

    @staticmethod
    def sanitize_checked(
        payload: dict[str, Any], base_resource: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        resource = payload.get("resource") or payload.get("Resource")
        if not isinstance(resource, dict):
            resource = payload
        last = payload.get("status") or payload.get("Status")
        if not isinstance(last, dict):
            last = payload.get("lastStatus")
        if not isinstance(last, dict):
            last = resource.get("lastStatus") or resource.get("LastStatus")
        if not isinstance(last, dict):
            direct_status = {
                key: resource.get(key)
                for key in (
                    "connectionStatus",
                    "pageStatus",
                    "pageMatchStatus",
                    "loginStatus",
                    "loginApiProbeStatus",
                    "loginConfidence",
                    "loginCheckedAt",
                    "checkedAt",
                    "watcherErrorCode",
                )
                if resource.get(key) not in (None, "")
            }
            last = direct_status
        last_status = last if isinstance(last, dict) else {}
        combined = dict(base_resource or {})
        for key, value in resource.items():
            if value not in (None, ""):
                combined[key] = value
        combined["lastStatus"] = last_status
        safe = project_resource(PortManagerAdapter._sanitize(combined))
        safe["pageStatus"] = _text(
            last_status.get("pageStatus")
            or last_status.get("pageMatchStatus")
            or last_status.get("pageUrl")
        ) or "未检查"
        return safe

    @staticmethod
    def merge_resource_state(
        base: dict[str, Any], update: dict[str, Any]
    ) -> dict[str, Any]:
        """Merge a live check without losing registered resource facts."""
        merged = dict(base)
        fact_keys = {"resourceId", "name", "platform", "port", "enabled"}
        for key, value in update.items():
            if key in fact_keys and merged.get(key) not in (None, ""):
                continue
            if value not in (None, ""):
                merged[key] = value
        return merged
