import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
import sys
from pathlib import Path


def now():
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat()


def jloads(value, default):
    if value in (None, ""):
        return default
    try:
        return json.loads(value)
    except Exception:
        return default


SENSITIVE_RE = re.compile(r"(?i)(password|passwd|token|cookie|authorization|auth(?:orization)?header)\s*[:=]\s*[^\s,;]+|Bearer\s+[A-Za-z0-9._~+/=-]{8,}")


def redact_sensitive_text(value):
    text = str(value or "")
    return SENSITIVE_RE.sub("[已脱敏]", text).replace("\r", " ").replace("\n", " ")[:512]


def redact_sensitive_value(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            result[key] = "[已脱敏]" if re.search(r"(?i)(password|passwd|cookie|token|authorization|authheader|secret|credentialvalue)", str(key)) else redact_sensitive_value(item)
        return result
    if isinstance(value, list):
        return [redact_sensitive_value(item) for item in value]
    return redact_sensitive_text(value) if isinstance(value, str) else value


def safe_legacy_error(value):
    text = redact_sensitive_text(value)
    return "legacy detector error imported; details omitted" if "{" in text or "}" in text else text


def connect(path):
    db = sqlite3.connect(path, timeout=10, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA busy_timeout=10000")
    db.execute("PRAGMA journal_mode=WAL")
    return db


SCHEMA = [
    "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)",
    """CREATE TABLE IF NOT EXISTS port_resources (
        resource_id TEXT PRIMARY KEY, platform_id TEXT NOT NULL, resource_name TEXT NOT NULL,
        platform_name TEXT NOT NULL, host_name TEXT NOT NULL, port INTEGER NOT NULL,
        connection_mode TEXT NOT NULL, browser_executable TEXT, browser_profile_directory TEXT,
        start_url TEXT, platform_url_patterns_json TEXT NOT NULL, login_page_patterns_json TEXT NOT NULL,
        enabled INTEGER NOT NULL, credential_ref TEXT, masked_account_summary TEXT,
        login_automation_state TEXT, session_policy_json TEXT NOT NULL, registered_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, notes TEXT, UNIQUE(host_name, port)
    )""",
    """CREATE TABLE IF NOT EXISTS port_runtime_states (
        resource_id TEXT PRIMARY KEY REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        connection_status TEXT, port_status TEXT, http_status TEXT, browser_status TEXT,
        page_status TEXT, login_status TEXT, login_evidence_json TEXT, login_checked_at TEXT,
        login_detection_state TEXT, next_login_detection_at TEXT, login_detection_source TEXT,
        login_detection_error_code TEXT, login_cookie_evidence_present INTEGER,
        login_api_probe_status TEXT, login_confidence TEXT, detector_version TEXT,
        current_occupancy_json TEXT, last_checked_at TEXT, last_success_at TEXT,
        last_error TEXT, operation_status TEXT, browser_version TEXT, protocol_version TEXT,
        debug_endpoint TEXT, matched_pages_json TEXT, profile_metrics_json TEXT
    )""",
    """CREATE TABLE IF NOT EXISTS login_state_checks (
        id INTEGER PRIMARY KEY AUTOINCREMENT, resource_id TEXT NOT NULL REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        attempt_id TEXT, state TEXT NOT NULL, evidence_type TEXT, evidence_summary TEXT,
        page_url_safe TEXT, page_title_safe TEXT, cookie_evidence_present INTEGER,
        api_probe_status TEXT, confidence TEXT, checked_at TEXT, error_code TEXT, detector_version TEXT, created_at TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS resource_leases (
        lease_id TEXT PRIMARY KEY, resource_id TEXT NOT NULL REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        operation TEXT NOT NULL, owner_process_id INTEGER, task_ref TEXT, created_at TEXT NOT NULL,
        expires_at TEXT NOT NULL, released_at TEXT, state TEXT NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_port_resources_enabled ON port_resources(enabled)",
    "CREATE INDEX IF NOT EXISTS idx_runtime_login_status ON port_runtime_states(login_status)",
    "CREATE INDEX IF NOT EXISTS idx_leases_resource_state_expiry ON resource_leases(resource_id,state,expires_at)",
    "CREATE INDEX IF NOT EXISTS idx_login_checks_resource_checked ON login_state_checks(resource_id,checked_at)",
    """CREATE TABLE IF NOT EXISTS audit_records (
        audit_id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT NOT NULL, resource_id TEXT,
        outcome TEXT NOT NULL, message TEXT, error_code TEXT, process_id INTEGER,
        created_at TEXT NOT NULL, details_json TEXT NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_audit_resource_created ON audit_records(resource_id,created_at)",
    """CREATE TABLE IF NOT EXISTS deleted_resource_history (
        resource_id TEXT PRIMARY KEY, resource_snapshot_json TEXT NOT NULL,
        login_checks_json TEXT NOT NULL, audit_records_json TEXT NOT NULL, archived_at TEXT NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_deleted_history_archived ON deleted_resource_history(archived_at)",
    """CREATE TABLE IF NOT EXISTS login_detection_tasks (
        attempt_id TEXT PRIMARY KEY, resource_id TEXT NOT NULL REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        state TEXT NOT NULL, process_id INTEGER, started_at TEXT NOT NULL, finished_at TEXT,
        timeout_at TEXT NOT NULL, next_retry_at TEXT, retry_count INTEGER NOT NULL DEFAULT 0,
        error_code TEXT, redacted_error TEXT, detector_version TEXT NOT NULL,
        stdout_path TEXT, stderr_path TEXT, cancelled_at TEXT
    )""",
    "CREATE INDEX IF NOT EXISTS idx_login_detection_tasks_resource_state ON login_detection_tasks(resource_id,state,timeout_at)",
    "ALTER TABLE port_runtime_states ADD COLUMN login_detection_started_at TEXT",
    "ALTER TABLE deleted_resource_history ADD COLUMN login_detection_tasks_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE deleted_resource_history ADD COLUMN resource_leases_json TEXT NOT NULL DEFAULT '[]'",
    "ALTER TABLE deleted_resource_history ADD COLUMN runtime_state_json TEXT NOT NULL DEFAULT '{}'",
    "ALTER TABLE port_runtime_states ADD COLUMN browser_pid INTEGER",
    "ALTER TABLE port_runtime_states ADD COLUMN process_start_time TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN profile_fingerprint TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN session_state TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN last_open_at TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN last_open_result TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_pid INTEGER",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_process_start_time TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_heartbeat_at TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_last_check_at TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_next_check_at TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_failure_count INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE port_runtime_states ADD COLUMN watcher_error_code TEXT",
    "ALTER TABLE port_runtime_states ADD COLUMN last_authenticated_at TEXT",
    """CREATE TABLE IF NOT EXISTS credential_profiles (
        credential_ref TEXT PRIMARY KEY, resource_id TEXT REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        credential_type TEXT NOT NULL, masked_summary TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )""",
    """CREATE TABLE IF NOT EXISTS login_session_events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        resource_id TEXT NOT NULL REFERENCES port_resources(resource_id) ON DELETE CASCADE,
        login_status TEXT NOT NULL, api_probe_status TEXT, confidence TEXT,
        evidence_json TEXT NOT NULL, error_code TEXT, checked_at TEXT NOT NULL,
        authenticated_at TEXT, browser_pid INTEGER, process_start_time TEXT, created_at TEXT NOT NULL
    )""",
    "CREATE INDEX IF NOT EXISTS idx_login_session_events_resource_checked ON login_session_events(resource_id,checked_at)",
]

SCHEMA_VERSION = len(SCHEMA)


def verify_migration_checksums(db):
    rows = db.execute("SELECT version,checksum FROM schema_migrations ORDER BY version").fetchall()
    expected = {version: hashlib.sha256(sql.encode("utf-8")).hexdigest() for version, sql in enumerate(SCHEMA, 1)}
    for row in rows:
        if row[0] not in expected or row[1] != expected[row[0]]:
            raise RuntimeError(f"schema migration checksum mismatch: version={row[0]}")


def ensure_columns(db):
    required = {
        "port_resources": {"notes": "TEXT"},
        "login_state_checks": {
            "page_url_safe": "TEXT", "page_title_safe": "TEXT", "cookie_evidence_present": "INTEGER",
            "api_probe_status": "TEXT", "confidence": "TEXT"
        }
    }
    for table, columns in required.items():
        present = {r[1] for r in db.execute(f"PRAGMA table_info({table})")}
        for name, sql_type in columns.items():
            if name not in present:
                db.execute(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")


def migrate(db_path, json_path, backup_dir):
    Path(db_path).parent.mkdir(parents=True, exist_ok=True)
    db = connect(db_path)
    marker_payload = None
    try:
        db.execute("BEGIN IMMEDIATE")
        db.execute(SCHEMA[0])
        applied = {r[0] for r in db.execute("SELECT version FROM schema_migrations")}
        for version, sql in enumerate(SCHEMA, 1):
            if version not in applied:
                db.execute(sql)
                checksum = hashlib.sha256(sql.encode("utf-8")).hexdigest()
                db.execute("INSERT INTO schema_migrations(version,name,checksum,applied_at) VALUES(?,?,?,?)", (version, f"phase1-{version}", checksum, now()))
        verify_migration_checksums(db)
        ensure_columns(db)
        # Initial JSON migration is idempotent and only runs when the DB has no resources.
        count = db.execute("SELECT COUNT(*) FROM port_resources").fetchone()[0]
        if count == 0 and os.path.isfile(json_path):
            with open(json_path, "r", encoding="utf-8-sig") as f:
                source = json.load(f)
            resources = source if isinstance(source, list) else (source.get("resources") or [])
            if resources:
                Path(backup_dir).mkdir(parents=True, exist_ok=True)
                backup = Path(backup_dir) / (Path(json_path).stem + ".migration-" + dt.datetime.now().strftime("%Y%m%d-%H%M%S") + ".json")
                shutil.copy2(json_path, backup)
                upsert_resources(db, resources)
        marker_payload = migrate_legacy_metadata(db, json_path, backup_dir)
        db.execute("COMMIT")
        if marker_payload is not None:
            marker = Path(backup_dir) / "legacy-metadata-migrated.json"
            marker.parent.mkdir(parents=True, exist_ok=True)
            marker.write_text(json.dumps(marker_payload, ensure_ascii=False), encoding="utf-8")
    except Exception:
        db.execute("ROLLBACK")
        raise
    finally:
        db.close()


def migrate_legacy_metadata(db, json_path, backup_dir):
    """Import only safe legacy lease/detection metadata once resources exist."""
    marker = Path(backup_dir) / "legacy-metadata-migrated.json"
    if marker.is_file() or db.execute("SELECT COUNT(*) FROM port_resources").fetchone()[0] == 0:
        return None
    root = Path(json_path).parent
    leases_path = root / "leases.json"
    detections_path = root / "login-detections.json"
    if leases_path.is_file():
        legacy = json.loads(leases_path.read_text(encoding="utf-8-sig"))
        for lease in legacy.get("leases") or []:
                rid = lease.get("resourceId")
                if not rid or not db.execute("SELECT 1 FROM port_resources WHERE resource_id=?", (rid,)).fetchone():
                    continue
                expires = lease.get("expiresAt") or lease.get("expires_at")
                if not expires:
                    continue
                state = "active"
                try:
                    if dt.datetime.fromisoformat(expires.replace("Z", "+00:00")) <= dt.datetime.now(dt.timezone.utc):
                        state = "expired"
                except Exception:
                    state = "expired"
                db.execute("INSERT OR IGNORE INTO resource_leases(lease_id,resource_id,operation,owner_process_id,task_ref,created_at,expires_at,released_at,state) VALUES(?,?,?,?,?,?,?,?,?)",
                           (lease.get("leaseId") or "legacy-" + hashlib.sha256(json.dumps(lease, sort_keys=True).encode()).hexdigest()[:16], rid,
                            lease.get("operation") or "legacy", lease.get("processId"), lease.get("taskRef"), lease.get("startedAt") or now(), expires,
                            now() if state == "expired" else None, state))
    if detections_path.is_file():
        legacy = json.loads(detections_path.read_text(encoding="utf-8-sig"))
        for record in legacy.get("records") or []:
                rid = record.get("resourceId")
                if not rid or not db.execute("SELECT 1 FROM port_resources WHERE resource_id=?", (rid,)).fetchone():
                    continue
                raw_state = str(record.get("state") or "").strip().lower()
                if raw_state in ("running", "检测中", "detecting"):
                    legacy_state = "running"
                elif raw_state in ("completed", "已完成", "success", "succeeded"):
                    legacy_state = "completed"
                elif raw_state in ("cancelled", "已取消", "canceled", "取消"):
                    legacy_state = "cancelled"
                elif raw_state in ("failed", "检测失败", "失败", "timeout", "超时"):
                    legacy_state = "failed"
                else:
                    legacy_state = "failed"
                db.execute("INSERT OR IGNORE INTO login_detection_tasks(attempt_id,resource_id,state,process_id,started_at,finished_at,timeout_at,next_retry_at,retry_count,error_code,redacted_error,detector_version,stdout_path,stderr_path) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           (record.get("attemptId") or "legacy-" + hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()[:16], rid,
                            legacy_state, record.get("processId"), record.get("startedAt") or now(), record.get("finishedAt"),
                            record.get("timeoutAt") or now(), record.get("nextRetryAt") or None, int(record.get("retryCount") or 0), record.get("errorCode") or None,
                            safe_legacy_error(record.get("redactedError")), record.get("detectorVersion") or "legacy", record.get("stdoutPath"), record.get("stderrPath")))
    return {"migratedAt": now(), "sources": [str(leases_path), str(detections_path)]}


def resource_row(r):
    return (
        r.get("resourceId"), r.get("platformId", "huice"), r.get("resourceName", ""), r.get("platformName", "慧策通"),
        r.get("hostName"), int(r.get("port")), r.get("connectionMode", "ConnectOnly"), r.get("browserExecutable"),
        r.get("browserProfileDirectory"), r.get("startUrl"), json.dumps(r.get("platformUrlPatterns") or [], ensure_ascii=False),
        json.dumps(r.get("loginPagePatterns") or [], ensure_ascii=False), 1 if r.get("enabled", True) else 0,
        r.get("credentialRef"), r.get("maskedAccountSummary"), r.get("loginAutomationState"),
        json.dumps(r.get("sessionPolicy") or {}, ensure_ascii=False), r.get("registeredAt") or now(), r.get("updatedAt") or now(), r.get("notes"))


def runtime_row(resource_id, s):
    s = s or {}
    return (resource_id, s.get("connectionStatus"), s.get("portStatus"), s.get("httpStatus"), s.get("browserStatus"), s.get("pageStatus"), s.get("loginStatus"),
            json.dumps(s.get("loginEvidence") or {}, ensure_ascii=False), s.get("loginCheckedAt"), s.get("loginDetectionState"), s.get("nextLoginDetectionAt"), s.get("loginDetectionSource"),
            s.get("loginDetectionErrorCode"), None if s.get("loginCookieEvidencePresent") is None else (1 if s.get("loginCookieEvidencePresent") else 0), s.get("loginApiProbeStatus"), s.get("loginConfidence"), s.get("detectorVersion"),
            json.dumps(s.get("currentOccupancyDetails") or {"activeLeases": s.get("activeLeases") or [], "ownerProcessIds": s.get("ownerProcessIds") or []}, ensure_ascii=False), s.get("lastCheckedAt"), s.get("lastSuccessAt"), s.get("lastError"), s.get("operationStatus"), s.get("browserVersion"), s.get("protocolVersion"), s.get("debugEndpoint"), json.dumps(s.get("matchedPages") or [], ensure_ascii=False), json.dumps(s.get("profileMetrics"), ensure_ascii=False), s.get("loginDetectionStartedAt"), s.get("browserPid"), s.get("processStartTime"), s.get("profileFingerprint"), s.get("sessionState"), s.get("lastOpenAt"), s.get("lastOpenResult"), s.get("watcherPid"), s.get("watcherProcessStartTime"), s.get("watcherHeartbeatAt"), s.get("watcherLastCheckAt"), s.get("watcherNextCheckAt"), s.get("watcherFailureCount", 0), s.get("watcherErrorCode"))


def sync_legacy_login_session_projection(db, resource_id):
    """Keep an optional legacy table aligned without making it authoritative."""
    if not db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='login_sessions'").fetchone():
        return False
    row = db.execute(
        """SELECT p.resource_id,p.platform_id,p.resource_name,p.host_name,p.port,
                  p.browser_profile_directory,p.credential_ref,
                  s.browser_pid,s.login_status,s.login_api_probe_status,
                  s.login_checked_at,s.last_authenticated_at,s.last_open_at,s.last_error
           FROM port_resources p
           JOIN port_runtime_states s ON s.resource_id=p.resource_id
           WHERE p.resource_id=?""",
        (resource_id,)).fetchone()
    if row is None:
        return False
    login_status = str(row["login_status"] or "")
    api_status = str(row["login_api_probe_status"] or "unknown")
    if login_status == "已登录" and api_status == "logged-in-api-ready":
        projected_status = "logged-in-api-ready"
    elif login_status == "已登录":
        projected_status = "logged-in"
    elif login_status == "未登录":
        projected_status = "login-required"
    elif login_status == "登录已失效":
        projected_status = "session-expired"
    elif login_status == "检测失败":
        projected_status = "detection-failed"
    else:
        projected_status = "unknown"
    checked_at = row["login_checked_at"] or now()
    updated_at = now()
    db.execute(
        """INSERT INTO login_sessions(
               resource_id,platform,display_name,host,port,profile_path,browser_pid,
               status,status_reason_code,evidence_summary,credential_ref,last_checked_at,
               last_authenticated_at,last_opened_at,lease_owner,lease_expires_at,
               schema_version,created_at,updated_at,api_auth_status,last_api_probe_at,last_error)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
           ON CONFLICT(resource_id) DO UPDATE SET
               platform=excluded.platform,display_name=excluded.display_name,
               host=excluded.host,port=excluded.port,profile_path=excluded.profile_path,
               browser_pid=excluded.browser_pid,status=excluded.status,
               status_reason_code=excluded.status_reason_code,
               evidence_summary=excluded.evidence_summary,
               credential_ref=excluded.credential_ref,
               last_checked_at=excluded.last_checked_at,
               last_authenticated_at=excluded.last_authenticated_at,
               last_opened_at=excluded.last_opened_at,
               lease_owner=NULL,lease_expires_at=NULL,
               schema_version=excluded.schema_version,updated_at=excluded.updated_at,
               api_auth_status=excluded.api_auth_status,
               last_api_probe_at=excluded.last_api_probe_at,
               last_error=excluded.last_error""",
        (row["resource_id"], row["platform_id"], row["resource_name"],
         row["host_name"], row["port"], row["browser_profile_directory"],
         row["browser_pid"], projected_status, "PORT_RUNTIME_STATE_PROJECTION",
         "Current compatibility projection from port_runtime_states.",
         row["credential_ref"], checked_at, row["last_authenticated_at"],
         row["last_open_at"], None, None, 2, updated_at, updated_at,
         api_status, checked_at, row["last_error"]))
    return True


def upsert_resources(db, resources):
    for r in resources:
        db.execute("INSERT INTO port_resources(resource_id,platform_id,resource_name,platform_name,host_name,port,connection_mode,browser_executable,browser_profile_directory,start_url,platform_url_patterns_json,login_page_patterns_json,enabled,credential_ref,masked_account_summary,login_automation_state,session_policy_json,registered_at,updated_at,notes) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(resource_id) DO UPDATE SET platform_id=excluded.platform_id,resource_name=excluded.resource_name,platform_name=excluded.platform_name,host_name=excluded.host_name,port=excluded.port,connection_mode=excluded.connection_mode,browser_executable=excluded.browser_executable,browser_profile_directory=excluded.browser_profile_directory,start_url=excluded.start_url,platform_url_patterns_json=excluded.platform_url_patterns_json,login_page_patterns_json=excluded.login_page_patterns_json,enabled=excluded.enabled,credential_ref=excluded.credential_ref,masked_account_summary=excluded.masked_account_summary,login_automation_state=excluded.login_automation_state,session_policy_json=excluded.session_policy_json,registered_at=excluded.registered_at,updated_at=excluded.updated_at,notes=excluded.notes", resource_row(r))
        db.execute("INSERT INTO port_runtime_states(resource_id,connection_status,port_status,http_status,browser_status,page_status,login_status,login_evidence_json,login_checked_at,login_detection_state,next_login_detection_at,login_detection_source,login_detection_error_code,login_cookie_evidence_present,login_api_probe_status,login_confidence,detector_version,current_occupancy_json,last_checked_at,last_success_at,last_error,operation_status,browser_version,protocol_version,debug_endpoint,matched_pages_json,profile_metrics_json,login_detection_started_at,browser_pid,process_start_time,profile_fingerprint,session_state,last_open_at,last_open_result,watcher_pid,watcher_process_start_time,watcher_heartbeat_at,watcher_last_check_at,watcher_next_check_at,watcher_failure_count,watcher_error_code) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(resource_id) DO UPDATE SET connection_status=excluded.connection_status,port_status=excluded.port_status,http_status=excluded.http_status,browser_status=excluded.browser_status,page_status=excluded.page_status,login_status=excluded.login_status,login_evidence_json=excluded.login_evidence_json,login_checked_at=excluded.login_checked_at,login_detection_state=excluded.login_detection_state,next_login_detection_at=excluded.next_login_detection_at,login_detection_source=excluded.login_detection_source,login_detection_error_code=excluded.login_detection_error_code,login_cookie_evidence_present=excluded.login_cookie_evidence_present,login_api_probe_status=excluded.login_api_probe_status,login_confidence=excluded.login_confidence,detector_version=excluded.detector_version,current_occupancy_json=excluded.current_occupancy_json,last_checked_at=excluded.last_checked_at,last_success_at=excluded.last_success_at,last_error=excluded.last_error,operation_status=excluded.operation_status,browser_version=excluded.browser_version,protocol_version=excluded.protocol_version,debug_endpoint=excluded.debug_endpoint,matched_pages_json=excluded.matched_pages_json,profile_metrics_json=excluded.profile_metrics_json,login_detection_started_at=excluded.login_detection_started_at,browser_pid=excluded.browser_pid,process_start_time=excluded.process_start_time,profile_fingerprint=excluded.profile_fingerprint,session_state=excluded.session_state,last_open_at=excluded.last_open_at,last_open_result=excluded.last_open_result,watcher_pid=excluded.watcher_pid,watcher_process_start_time=excluded.watcher_process_start_time,watcher_heartbeat_at=excluded.watcher_heartbeat_at,watcher_last_check_at=excluded.watcher_last_check_at,watcher_next_check_at=excluded.watcher_next_check_at,watcher_failure_count=excluded.watcher_failure_count,watcher_error_code=excluded.watcher_error_code", runtime_row(r["resourceId"], r.get("lastStatus")))
        sync_legacy_login_session_projection(db, r["resourceId"])


def delete_resource(db, resource_id):
    archive_deleted_resource(db, resource_id)
    db.execute("DELETE FROM port_resources WHERE resource_id=?", (resource_id,))


def archive_deleted_resource(db, resource_id):
    resource = db.execute("SELECT * FROM port_resources WHERE resource_id=?", (resource_id,)).fetchone()
    if resource is None:
        return
    checks = [dict(r) for r in db.execute("SELECT * FROM login_state_checks WHERE resource_id=? ORDER BY checked_at", (resource_id,)).fetchall()]
    tasks = [dict(r) for r in db.execute("SELECT * FROM login_detection_tasks WHERE resource_id=? ORDER BY started_at", (resource_id,)).fetchall()]
    leases = [dict(r) for r in db.execute("SELECT * FROM resource_leases WHERE resource_id=? ORDER BY created_at", (resource_id,)).fetchall()]
    runtime = db.execute("SELECT * FROM port_runtime_states WHERE resource_id=?", (resource_id,)).fetchone()
    audits = [dict(r) for r in db.execute("SELECT * FROM audit_records WHERE resource_id=? ORDER BY created_at", (resource_id,)).fetchall()]
    snapshot = dict(resource)
    db.execute(
        "INSERT OR REPLACE INTO deleted_resource_history(resource_id,resource_snapshot_json,login_checks_json,audit_records_json,archived_at,login_detection_tasks_json,resource_leases_json,runtime_state_json) VALUES(?,?,?,?,?,?,?,?)",
        (resource_id, json.dumps(snapshot, ensure_ascii=False), json.dumps(checks, ensure_ascii=False), json.dumps(audits, ensure_ascii=False), now(), json.dumps(tasks, ensure_ascii=False), json.dumps(leases, ensure_ascii=False), json.dumps(dict(runtime) if runtime else {}, ensure_ascii=False)))


def read_store(db):
    resources = []
    rows = db.execute("SELECT p.resource_id,p.platform_id,p.resource_name,p.platform_name,p.host_name,p.port,p.connection_mode,p.browser_executable,p.browser_profile_directory,p.start_url,p.platform_url_patterns_json,p.login_page_patterns_json,p.enabled,p.credential_ref,p.masked_account_summary,p.login_automation_state,p.session_policy_json,p.registered_at,p.updated_at,p.notes,s.* FROM port_resources p LEFT JOIN port_runtime_states s ON s.resource_id=p.resource_id ORDER BY p.resource_id").fetchall()
    leases = read_leases(db)
    for row in rows:
        s = {"connectionStatus": row[21], "portStatus": row[22], "httpStatus": row[23], "browserStatus": row[24], "pageStatus": row[25], "loginStatus": row[26], "loginEvidence": jloads(row[27], {}), "loginCheckedAt": row[28], "loginDetectionState": row[29], "nextLoginDetectionAt": row[30], "loginDetectionSource": row[31], "loginDetectionErrorCode": row[32], "loginCookieEvidencePresent": None if row[33] is None else bool(row[33]), "loginApiProbeStatus": row[34], "loginConfidence": row[35], "detectorVersion": row[36], "currentOccupancyDetails": jloads(row[37], {}), "lastCheckedAt": row[38], "lastSuccessAt": row[39], "lastError": row[40], "operationStatus": row[41], "browserVersion": row[42], "protocolVersion": row[43], "debugEndpoint": row[44], "matchedPages": jloads(row[45], []), "profileMetrics": jloads(row[46], None), "loginDetectionStartedAt": row[47], "browserPid": row[48], "processStartTime": row[49], "profileFingerprint": row[50], "sessionState": row[51], "lastOpenAt": row[52], "lastOpenResult": row[53], "watcherPid": row[54], "watcherProcessStartTime": row[55], "watcherHeartbeatAt": row[56], "watcherLastCheckAt": row[57], "watcherNextCheckAt": row[58], "watcherFailureCount": row[59], "watcherErrorCode": row[60], "lastAuthenticatedAt": row[61]}
        own = [l for l in leases if l["resourceId"] == row[0]]
        s["activeLeases"] = own
        s["ownerProcessIds"] = s.get("currentOccupancyDetails", {}).get("ownerProcessIds", [])
        owner_ids = s.get("ownerProcessIds") or []
        if owner_ids and not own:
            s["currentOccupancy"] = "Chrome(PID " + ",".join([str(pid) for pid in owner_ids]) + ")"
        s["currentOccupancy"] = s.get("currentOccupancyDetails", {}).get("currentOccupancy") or ("、".join(["租约:%s(PID %s)" % (l["operation"], l["processId"]) for l in own]) if own else "无")
        if owner_ids and not own:
            s["currentOccupancy"] = "Chrome(PID " + ",".join([str(pid) for pid in owner_ids]) + ")"
        resources.append({"resourceId": row[0], "platformId": row[1], "resourceName": row[2], "platformName": row[3], "hostName": row[4], "port": row[5], "connectionMode": row[6], "browserExecutable": row[7], "browserProfileDirectory": row[8], "startUrl": row[9], "platformUrlPatterns": jloads(row[10], []), "loginPagePatterns": jloads(row[11], []), "enabled": bool(row[12]), "credentialRef": row[13], "maskedAccountSummary": row[14], "loginAutomationState": row[15], "sessionPolicy": jloads(row[16], {}), "registeredAt": row[17], "updatedAt": row[18], "notes": row[19], "lastStatus": s})
    version = db.execute("SELECT COALESCE(MAX(version),0) FROM schema_migrations").fetchone()[0]
    return {"schemaVersion": version, "updatedAt": now(), "resources": resources}


def read_leases(db):
    current = now()
    db.execute("UPDATE resource_leases SET state='expired',released_at=? WHERE state='active' AND expires_at < ?", (current, current))
    rows = db.execute("SELECT lease_id,resource_id,operation,owner_process_id,task_ref,created_at,expires_at FROM resource_leases WHERE state='active'").fetchall()
    return [{"leaseId": r[0], "resourceId": r[1], "operation": r[2], "processId": r[3], "taskRef": r[4], "startedAt": r[5], "expiresAt": r[6]} for r in rows]


def reclaim_stale_lease(db, payload):
    """Atomically reclaim only the exact active lease instance already verified by PowerShell."""
    expected_task_ref = payload.get("expectedTaskRef")
    row = db.execute(
        """SELECT lease_id,resource_id,operation,owner_process_id,task_ref,created_at,expires_at
             FROM resource_leases
            WHERE lease_id=? AND resource_id=? AND state='active'
              AND owner_process_id=? AND created_at=?
              AND (task_ref=? OR (task_ref IS NULL AND ? IS NULL))""",
        (payload["leaseId"], payload["resourceId"], payload["expectedProcessId"],
         payload["expectedStartedAt"], expected_task_ref, expected_task_ref)).fetchone()
    if row is None:
        return {"reclaimed": False, "auditId": None}

    released_at = payload.get("checkedAt") or now()
    cursor = db.execute(
        """UPDATE resource_leases
              SET state='reclaimed', released_at=?
            WHERE lease_id=? AND resource_id=? AND state='active'
              AND owner_process_id=? AND created_at=?
              AND (task_ref=? OR (task_ref IS NULL AND ? IS NULL))""",
        (released_at, payload["leaseId"], payload["resourceId"],
         payload["expectedProcessId"], payload["expectedStartedAt"],
         expected_task_ref, expected_task_ref))
    if cursor.rowcount != 1:
        return {"reclaimed": False, "auditId": None}

    error_code = redact_sensitive_text(
        payload.get("errorCode") or "LEASE_OWNER_PROCESS_NOT_FOUND")
    audit_id = add_audit(db, {
        "action": "LeaseAutoReclaim",
        "resourceId": row["resource_id"],
        "outcome": "Recovered",
        "message": "已回收原持有进程不存在或实例不匹配的活动租约。",
        "errorCode": error_code,
        "processId": payload.get("checkerProcessId"),
        "createdAt": released_at,
        "details": {
            "leaseId": row["lease_id"],
            "operation": row["operation"],
            "ownerProcessId": row["owner_process_id"],
            "leaseStartedAt": row["created_at"],
            "leaseExpiresAt": row["expires_at"],
            "reason": error_code,
            "checkerProcessId": payload.get("checkerProcessId"),
        },
    })
    return {"reclaimed": True, "auditId": audit_id}


def mark_watcher_invalid(db, payload):
    resource_id = payload["resourceId"]
    expected_pid = payload["expectedPid"]
    expected_start = payload.get("expectedProcessStartTime")
    error_code = redact_sensitive_text(payload.get("errorCode") or "WATCHER_PROCESS_NOT_FOUND")
    checked_at = payload.get("checkedAt") or now()
    cursor = db.execute(
        """UPDATE port_runtime_states SET
               watcher_pid=NULL,watcher_process_start_time=NULL,
               watcher_heartbeat_at=NULL,watcher_next_check_at=NULL,
               watcher_failure_count=COALESCE(watcher_failure_count,0)+1,
               watcher_error_code=?
           WHERE resource_id=? AND watcher_pid=?
             AND (watcher_process_start_time=? OR
                  (watcher_process_start_time IS NULL AND ? IS NULL))""",
        (error_code, resource_id, expected_pid, expected_start, expected_start))
    if cursor.rowcount == 1:
        add_audit(db, {
            "action": "WatcherHealth",
            "resourceId": resource_id,
            "outcome": "Degraded",
            "message": error_code,
            "errorCode": error_code,
            "processId": payload.get("checkerProcessId"),
            "details": {
                "invalidWatcherPid": expected_pid,
                "checkedAt": checked_at,
                "fallback": "on-demand-check"
            }
        })
    return cursor.rowcount == 1


def read_detection_task(db, resource_id):
    row = db.execute("SELECT attempt_id,resource_id,state,process_id,started_at,finished_at,timeout_at,next_retry_at,retry_count,error_code,redacted_error,detector_version,stdout_path,stderr_path,cancelled_at FROM login_detection_tasks WHERE resource_id=? ORDER BY started_at DESC LIMIT 1", (resource_id,)).fetchone()
    if row is None:
        return None
    return {"attemptId": row[0], "resourceId": row[1], "state": row[2], "processId": row[3], "startedAt": row[4], "finishedAt": row[5], "timeoutAt": row[6], "nextRetryAt": row[7], "retryCount": row[8], "errorCode": row[9], "redactedError": row[10], "detectorVersion": row[11], "stdoutPath": row[12], "stderrPath": row[13], "cancelledAt": row[14]}


def add_login_check(db, payload):
    """Persist only the redacted detector result; never accept raw credentials or headers."""
    summary = redact_sensitive_text(payload.get("evidenceSummary"))
    lowered = summary.lower()
    for marker in ("cookie", "token", "authorization", "password", "passwd"):
        if marker in lowered and "[已脱敏]" not in summary:
            raise RuntimeError("login evidence summary contains a sensitive marker")
    db.execute(
        "INSERT INTO login_state_checks(resource_id,attempt_id,state,evidence_type,evidence_summary,page_url_safe,page_title_safe,cookie_evidence_present,api_probe_status,confidence,checked_at,error_code,detector_version,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (payload["resourceId"], payload.get("attemptId"), payload["state"], payload.get("evidenceType"), summary,
         redact_sensitive_text(payload.get("pageUrlSafe")), redact_sensitive_text(payload.get("pageTitleSafe")), payload.get("cookieEvidencePresent"), redact_sensitive_text(payload.get("apiProbeStatus")), payload.get("confidence"),
         payload.get("checkedAt") or now(), redact_sensitive_text(payload.get("errorCode")), payload.get("detectorVersion"), now()))


def add_audit(db, payload):
    message = redact_sensitive_text(payload.get("message"))
    details = redact_sensitive_value(payload.get("details") or {})
    raw = json.dumps(details, ensure_ascii=False)
    db.execute(
        "INSERT INTO audit_records(action,resource_id,outcome,message,error_code,process_id,created_at,details_json) VALUES(?,?,?,?,?,?,?,?)",
        (payload["action"], payload.get("resourceId"), payload["outcome"], message, payload.get("errorCode"), payload.get("processId"), payload.get("createdAt") or now(), raw))
    return db.execute("SELECT last_insert_rowid()").fetchone()[0]


def record_login_runtime(db, payload):
    resource_id = payload["resourceId"]
    if not db.execute("SELECT 1 FROM port_resources WHERE resource_id=?", (resource_id,)).fetchone():
        raise RuntimeError("resource not found")
    checked_at = payload.get("checkedAt") or now()
    status = redact_sensitive_text(payload.get("loginStatus") or "检测失败")
    api_status = redact_sensitive_text(payload.get("apiProbeStatus") or "not-run")
    confidence = redact_sensitive_text(payload.get("confidence") or "unknown")
    error_code = redact_sensitive_text(payload.get("errorCode")) or None
    last_error = redact_sensitive_text(payload.get("lastError")) or None
    authenticated_at = payload.get("lastAuthenticatedAt")
    evidence = redact_sensitive_value(payload.get("evidence") or {})
    evidence_json = json.dumps(evidence, ensure_ascii=False)
    credential_ref = redact_sensitive_text(payload.get("credentialRef")) or None
    credential_type = redact_sensitive_text(payload.get("credentialType")) or None
    masked_summary = redact_sensitive_text(payload.get("maskedAccountSummary")) or None
    if credential_ref:
        db.execute(
            """INSERT INTO credential_profiles(credential_ref,resource_id,credential_type,masked_summary,created_at,updated_at)
               VALUES(?,?,?,?,?,?)
               ON CONFLICT(credential_ref) DO UPDATE SET
               resource_id=excluded.resource_id,credential_type=excluded.credential_type,
               masked_summary=excluded.masked_summary,updated_at=excluded.updated_at""",
            (credential_ref, resource_id, credential_type or "terminal-secure-input", masked_summary, now(), now()))
        db.execute(
            """UPDATE port_resources SET credential_ref=?,masked_account_summary=?,
               login_automation_state='huice-same-origin-http-login',updated_at=? WHERE resource_id=?""",
            (credential_ref, masked_summary, now(), resource_id))
    else:
        db.execute(
            """UPDATE port_resources SET login_automation_state='huice-same-origin-http-login',updated_at=?
               WHERE resource_id=? AND credential_ref IS NOT NULL""",
            (now(), resource_id))
    detection_state = "已完成" if not error_code else "检测失败"
    next_retry_at = payload.get("nextRetryAt")
    db.execute(
        """UPDATE port_runtime_states SET
           login_status=?,login_evidence_json=?,login_checked_at=?,login_detection_state=?,
           next_login_detection_at=?,login_detection_source='huice-login-agent',
           login_detection_error_code=?,login_cookie_evidence_present=?,
           login_api_probe_status=?,login_confidence=?,detector_version='huice-login-agent-v1',
           last_error=?,last_checked_at=?,last_success_at=CASE WHEN ? IS NOT NULL THEN ? ELSE last_success_at END,
           browser_pid=COALESCE(?,browser_pid),process_start_time=COALESCE(?,process_start_time),
           profile_fingerprint=COALESCE(?,profile_fingerprint),
           session_state=COALESCE(?,session_state),
           watcher_pid=COALESCE(?,watcher_pid),
           watcher_process_start_time=COALESCE(?,watcher_process_start_time),
           watcher_heartbeat_at=COALESCE(?,watcher_heartbeat_at),
           watcher_last_check_at=COALESCE(?,watcher_last_check_at),
           watcher_next_check_at=COALESCE(?,watcher_next_check_at),
           watcher_failure_count=CASE
               WHEN ? IS NULL THEN watcher_failure_count
               WHEN ? IS NULL THEN 0
               ELSE watcher_failure_count+1 END,
           watcher_error_code=CASE WHEN ? IS NULL THEN watcher_error_code ELSE ? END,
           last_authenticated_at=COALESCE(?,last_authenticated_at)
           WHERE resource_id=?""",
        (status, evidence_json, checked_at, detection_state, next_retry_at, error_code,
         payload.get("authMaterialPresent"), api_status, confidence, last_error, checked_at,
         authenticated_at, checked_at, payload.get("browserPid"), payload.get("processStartTime"),
         payload.get("profileFingerprint"),
         payload.get("sessionState"), payload.get("watcherPid"), payload.get("watcherProcessStartTime"),
         payload.get("watcherHeartbeatAt"), payload.get("watcherLastCheckAt"), payload.get("watcherNextCheckAt"),
         payload.get("watcherPid"), payload.get("watcherErrorCode"),
         payload.get("watcherPid"), payload.get("watcherErrorCode"),
         authenticated_at, resource_id))
    db.execute(
        """INSERT INTO login_session_events(
           resource_id,login_status,api_probe_status,confidence,evidence_json,error_code,
           checked_at,authenticated_at,browser_pid,process_start_time,created_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
        (resource_id, status, api_status, confidence, evidence_json, error_code, checked_at,
         authenticated_at, payload.get("browserPid"), payload.get("processStartTime"), now()))
    sync_legacy_login_session_projection(db, resource_id)
    add_audit(db, {
        "action": payload.get("auditAction") or "HuiceLoginState",
        "resourceId": resource_id,
        "outcome": "Success" if not error_code else "Failed",
        "message": payload.get("auditMessage") or status,
        "errorCode": error_code,
        "processId": payload.get("processId"),
        "details": {"loginStatus": status, "apiProbeStatus": api_status, "confidence": confidence,
                    "nextRetryAt": next_retry_at}
    })


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--action", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--payload")
    args = ap.parse_args()
    payload = {}
    if args.payload:
        with open(args.payload, "r", encoding="utf-8-sig") as f:
            payload = json.load(f)
        if args.action == "migrate":
            migrate(args.db, payload["jsonPath"], payload["backupDir"]); print(json.dumps({"ok": True, "schemaVersion": SCHEMA_VERSION}, ensure_ascii=False)); return
    db = connect(args.db)
    try:
        if args.action == "read_store":
            print(json.dumps(read_store(db), ensure_ascii=False)); return
        if args.action == "integrity_check":
            result = db.execute("PRAGMA integrity_check").fetchone()[0]
            print(json.dumps({"ok": result == "ok", "integrity": result, "schemaVersion": SCHEMA_VERSION}, ensure_ascii=False)); return
        if args.action == "backup_database":
            destination = Path(payload["destination"])
            if destination.drive.upper() != "F:":
                raise RuntimeError("SQLite 备份目标必须位于 F 盘")
            destination.parent.mkdir(parents=True, exist_ok=True)
            target = sqlite3.connect(str(destination))
            try:
                db.backup(target)
            finally:
                target.close()
            print(json.dumps({"ok": True, "destination": str(destination)}, ensure_ascii=False)); return
        if args.action == "save_store":
            db.execute("BEGIN IMMEDIATE"); upsert_resources(db, payload.get("resources", [])); db.execute("COMMIT"); print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "delete_resource":
            db.execute("BEGIN IMMEDIATE"); delete_resource(db, payload["resourceId"]); db.execute("COMMIT"); print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "read_leases":
            print(json.dumps({"schemaVersion": SCHEMA_VERSION, "leases": read_leases(db)}, ensure_ascii=False)); return
        if args.action == "reclaim_stale_lease":
            db.execute("BEGIN IMMEDIATE")
            reclaimed = reclaim_stale_lease(db, payload)
            db.execute("COMMIT")
            print(json.dumps({"ok": True, **reclaimed}, ensure_ascii=False)); return
        if args.action == "mark_watcher_invalid":
            db.execute("BEGIN IMMEDIATE")
            updated = mark_watcher_invalid(db, payload)
            db.execute("COMMIT")
            print(json.dumps({"ok": True, "updated": updated,
                              "resourceId": payload["resourceId"]}, ensure_ascii=False)); return
        if args.action == "add_lease":
            db.execute("BEGIN IMMEDIATE");
            if not db.execute("SELECT 1 FROM port_resources WHERE resource_id=?", (payload["resourceId"],)).fetchone(): raise RuntimeError("resource not found")
            if not db.execute("SELECT enabled FROM port_resources WHERE resource_id=? AND enabled=1", (payload["resourceId"],)).fetchone(): raise RuntimeError("resource disabled")
            current = now()
            db.execute("UPDATE resource_leases SET state='expired',released_at=? WHERE state='active' AND expires_at <= ?", (current, current))
            active = db.execute("SELECT lease_id,resource_id,operation,owner_process_id,task_ref,created_at,expires_at FROM resource_leases WHERE resource_id=? AND state='active' ORDER BY created_at LIMIT 1", (payload["resourceId"],)).fetchone()
            if active:
                db.execute("COMMIT")
                print(json.dumps({"ok": False, "errorCode": "RESOURCE_BUSY", "error": "RESOURCE_BUSY",
                                  "activeLease": {"leaseId": active[0], "resourceId": active[1],
                                                  "operation": active[2], "processId": active[3],
                                                  "taskRef": active[4], "startedAt": active[5],
                                                  "expiresAt": active[6]}}, ensure_ascii=False))
                return
            db.execute("INSERT INTO resource_leases(lease_id,resource_id,operation,owner_process_id,task_ref,created_at,expires_at,state) VALUES(?,?,?,?,?,?,?,'active')", (payload["leaseId"],payload["resourceId"],payload["operation"],payload.get("processId"),payload.get("taskRef"),payload["startedAt"],payload["expiresAt"]))
            db.execute("COMMIT"); print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "release_lease":
            db.execute("UPDATE resource_leases SET state='released',released_at=? WHERE lease_id=? AND state='active'", (now(), payload["leaseId"])); print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "read_detection_task":
            print(json.dumps({"schemaVersion": SCHEMA_VERSION, "task": read_detection_task(db, payload["resourceId"])}, ensure_ascii=False)); return
        if args.action == "start_detection_task":
            db.execute("BEGIN IMMEDIATE")
            if not db.execute("SELECT 1 FROM port_resources WHERE resource_id=?", (payload["resourceId"],)).fetchone(): raise RuntimeError("resource not found")
            existing = db.execute("SELECT attempt_id,state,timeout_at FROM login_detection_tasks WHERE resource_id=? AND state='running' ORDER BY started_at DESC LIMIT 1", (payload["resourceId"],)).fetchone()
            if existing:
                try:
                    expired = dt.datetime.fromisoformat(existing[2].replace("Z", "+00:00")) <= dt.datetime.now(dt.timezone.utc)
                except Exception:
                    expired = True
                if not expired:
                    db.execute("COMMIT"); print(json.dumps({"ok": False, "error": "LOGIN_DETECTION_IN_FLIGHT", "attemptId": existing[0]}, ensure_ascii=False)); return
                db.execute("COMMIT"); print(json.dumps({"ok": False, "error": "LOGIN_DETECTION_EXPIRED_REQUIRES_REAP", "attemptId": existing[0]}, ensure_ascii=False)); return
            db.execute("INSERT INTO login_detection_tasks(attempt_id,resource_id,state,process_id,started_at,timeout_at,retry_count,detector_version,stdout_path,stderr_path) VALUES(?,?,?,?,?,?,?,?,?,?)", (payload["attemptId"],payload["resourceId"],"running",payload.get("processId"),payload["startedAt"],payload["timeoutAt"],payload.get("retryCount",0),payload.get("detectorVersion","1"),payload.get("stdoutPath"),payload.get("stderrPath")))
            db.execute("COMMIT"); print(json.dumps({"ok": True, "task": read_detection_task(db, payload["resourceId"])}, ensure_ascii=False)); return
        if args.action == "complete_detection_task":
            if payload.get("state") not in ("completed", "failed", "cancelled"):
                raise RuntimeError("invalid login detection terminal state")
            db.execute("BEGIN IMMEDIATE")
            cursor = db.execute("UPDATE login_detection_tasks SET state=?,finished_at=?,next_retry_at=?,error_code=?,redacted_error=? WHERE attempt_id=? AND resource_id=? AND state='running'", (payload["state"],payload.get("finishedAt") or now(),payload.get("nextRetryAt"),redact_sensitive_text(payload.get("errorCode")),redact_sensitive_text(payload.get("redactedError")),payload["attemptId"],payload["resourceId"]))
            if cursor.rowcount != 1:
                add_audit(db, {"action": "LoginDetectionLateCompletion", "resourceId": payload["resourceId"], "outcome": "Rejected", "message": "迟到的登录检测结果未覆盖已收口任务。", "errorCode": "LOGIN_DETECTION_STALE_RESULT", "processId": payload.get("processId"), "details": {"attemptId": payload["attemptId"], "requestedState": payload.get("state"), "workerProcessId": payload.get("processId")}})
                db.execute("COMMIT"); print(json.dumps({"ok": False, "stale": True, "error": "LOGIN_DETECTION_STALE_RESULT"}, ensure_ascii=False)); return
            db.execute("COMMIT"); print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "set_detection_process":
            db.execute("UPDATE login_detection_tasks SET process_id=? WHERE attempt_id=? AND state='running'", (payload["processId"], payload["attemptId"]))
            if db.total_changes == 0:
                raise RuntimeError("login detection task is not running or attemptId is unknown")
            print(json.dumps({"ok": True, "processId": payload["processId"]}, ensure_ascii=False)); return
        if args.action == "read_expired_detection_tasks":
            current = now()
            rows = db.execute("SELECT attempt_id,resource_id,state,process_id,started_at,finished_at,timeout_at,next_retry_at,retry_count,error_code,redacted_error,detector_version,stdout_path,stderr_path,cancelled_at FROM login_detection_tasks WHERE state='running' AND timeout_at <= ? ORDER BY timeout_at", (current,)).fetchall()
            print(json.dumps({"schemaVersion": SCHEMA_VERSION, "tasks": [dict(r) for r in rows]}, ensure_ascii=False)); return
        if args.action == "mark_detection_reap_failed":
            db.execute("BEGIN IMMEDIATE")
            cursor = db.execute("UPDATE login_detection_tasks SET error_code=?,redacted_error=? WHERE attempt_id=? AND resource_id=? AND state='running'", ("LOGIN_DETECTION_REAP_FAILED", "login detection process could not be reaped; task remains occupied", payload["attemptId"], payload["resourceId"]))
            db.execute("COMMIT"); print(json.dumps({"ok": cursor.rowcount == 1, "stillRunning": cursor.rowcount == 1}, ensure_ascii=False)); return
        if args.action == "cancel_detection_task":
            db.execute("BEGIN IMMEDIATE")
            db.execute("UPDATE login_detection_tasks SET state='cancelled',finished_at=?,cancelled_at=?,error_code='LOGIN_DETECTION_CANCELLED',redacted_error=? WHERE resource_id=? AND state='running'", (now(),now(),"login detection cancelled",payload["resourceId"]))
            db.execute("COMMIT"); print(json.dumps({"ok": True, "task": read_detection_task(db, payload["resourceId"])}, ensure_ascii=False)); return
        if args.action == "add_login_check":
            db.execute("BEGIN IMMEDIATE")
            add_login_check(db, payload)
            db.execute("COMMIT")
            print(json.dumps({"ok": True}, ensure_ascii=False)); return
        if args.action == "add_audit":
            db.execute("BEGIN IMMEDIATE")
            audit_id = add_audit(db, payload)
            db.execute("COMMIT")
            print(json.dumps({"ok": True, "auditId": audit_id}, ensure_ascii=False)); return
        if args.action == "record_login_runtime":
            db.execute("BEGIN IMMEDIATE")
            record_login_runtime(db, payload)
            db.execute("COMMIT")
            print(json.dumps({"ok": True, "resourceId": payload["resourceId"]}, ensure_ascii=False)); return
        raise RuntimeError("unsupported action")
    except Exception:
        try: db.execute("ROLLBACK")
        except Exception: pass
        raise
    finally:
        db.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        sys.exit(1)
