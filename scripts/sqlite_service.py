#!/usr/bin/env python3
import argparse
import datetime as _dt
import json
import sqlite3
import sys


SCHEMA_VERSION = 1
TERMINAL_STATES = {
    "SUCCEEDED",
    "FAILED",
    "CANCELED",
    "TIMED_OUT",
    "BLOCKED",
    "AUTH_REQUIRED",
    "RESOURCE_BUSY",
    "RECOVERY_REQUIRED",
}


def utc_now():
    return _dt.datetime.now(_dt.timezone.utc).isoformat()


def connect(db_path):
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    return conn


def init(conn):
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS selection_tasks (
            task_id TEXT PRIMARY KEY,
            selection_action TEXT NOT NULL,
            status TEXT NOT NULL,
            phase TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            request_json TEXT,
            resource_snapshot_json TEXT,
            result_json TEXT,
            recovery_required INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS selection_events (
            event_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            status TEXT NOT NULL,
            phase TEXT NOT NULL,
            message TEXT,
            source TEXT,
            evidence_json TEXT,
            next_action TEXT,
            at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS selection_candidates (
            snapshot_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            source TEXT,
            source_at TEXT,
            item_count INTEGER NOT NULL DEFAULT 0,
            redacted_summary_json TEXT,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS selection_actions (
            action_record_id TEXT PRIMARY KEY,
            task_id TEXT NOT NULL,
            action_id TEXT NOT NULL,
            idempotency_key TEXT,
            external_ref TEXT,
            status TEXT NOT NULL,
            readback_at TEXT,
            redacted_result_json TEXT,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS selection_rules (
            rule_version TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            summary_json TEXT,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS selection_recoveries (
            recovery_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL,
            reason TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            closed_at TEXT
        );
        CREATE TABLE IF NOT EXISTS selection_audits (
            audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT,
            event_type TEXT NOT NULL,
            redacted_payload_json TEXT,
            created_at TEXT NOT NULL
        );
        """
    )
    conn.execute(
        "INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(?, ?)",
        (SCHEMA_VERSION, utc_now()),
    )
    conn.commit()
    return {"ok": True, "schemaVersion": SCHEMA_VERSION}


def dump_json(value):
    if value is None:
        return None
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def load_json(value):
    if not value:
        return None
    return json.loads(value)


def save_task(conn, record):
    conn.execute(
        """
        INSERT INTO selection_tasks(task_id, selection_action, status, phase, created_at, updated_at, request_json, resource_snapshot_json, result_json, recovery_required)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(task_id) DO UPDATE SET
          status=excluded.status,
          phase=excluded.phase,
          updated_at=excluded.updated_at,
          request_json=excluded.request_json,
          resource_snapshot_json=excluded.resource_snapshot_json,
          result_json=excluded.result_json,
          recovery_required=excluded.recovery_required
        """,
        (
            record["taskId"],
            record["selectionAction"],
            record["status"],
            record["phase"],
            record.get("createdAt") or utc_now(),
            record.get("updatedAt") or utc_now(),
            dump_json(record.get("request")),
            dump_json(record.get("resourceSnapshot")),
            dump_json(record.get("result")),
            1 if record.get("recoveryRequired") else 0,
        ),
    )
    conn.execute(
        "INSERT INTO selection_audits(task_id, event_type, redacted_payload_json, created_at) VALUES(?, ?, ?, ?)",
        (record["taskId"], "task_saved", dump_json(record), utc_now()),
    )
    conn.commit()
    return {"ok": True, "taskId": record["taskId"], "status": record["status"]}


def add_event(conn, record):
    conn.execute(
        """
        INSERT INTO selection_events(task_id, status, phase, message, source, evidence_json, next_action, at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record["taskId"],
            record["status"],
            record["phase"],
            record.get("message"),
            record.get("source"),
            dump_json(record.get("evidence")),
            record.get("nextAction"),
            record.get("at") or utc_now(),
        ),
    )
    conn.execute(
        "INSERT INTO selection_audits(task_id, event_type, redacted_payload_json, created_at) VALUES(?, ?, ?, ?)",
        (record["taskId"], "state_transition", dump_json(record), utc_now()),
    )
    if record["status"] == "RECOVERY_REQUIRED":
        conn.execute(
            "INSERT INTO selection_recoveries(task_id, reason, status, created_at) VALUES(?, ?, ?, ?)",
            (record["taskId"], record.get("message") or "recovery required", "OPEN", utc_now()),
        )
    conn.commit()
    return {"ok": True, "taskId": record["taskId"], "status": record["status"]}


def get_task(conn, task_id):
    row = conn.execute("SELECT * FROM selection_tasks WHERE task_id=?", (task_id,)).fetchone()
    if not row:
        return {"ok": False, "status": "NOT_FOUND", "taskId": task_id}
    events = [
        dict(x)
        for x in conn.execute(
            "SELECT status, phase, message, source, evidence_json, next_action, at FROM selection_events WHERE task_id=? ORDER BY event_id",
            (task_id,),
        )
    ]
    for event in events:
        event["evidence"] = load_json(event.pop("evidence_json"))
        event["nextAction"] = event.pop("next_action")
    return {
        "ok": True,
        "taskId": row["task_id"],
        "selectionAction": row["selection_action"],
        "status": row["status"],
        "phase": row["phase"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "request": load_json(row["request_json"]),
        "resourceSnapshot": load_json(row["resource_snapshot_json"]),
        "result": load_json(row["result_json"]),
        "recoveryRequired": bool(row["recovery_required"]),
        "events": events,
    }


def set_terminal(conn, task_id, status, reason, at):
    row = conn.execute("SELECT status FROM selection_tasks WHERE task_id=?", (task_id,)).fetchone()
    if not row:
        return {"ok": False, "status": "NOT_FOUND", "taskId": task_id}
    if row["status"] in TERMINAL_STATES:
        return {"ok": True, "status": row["status"], "taskId": task_id, "message": "already terminal"}
    conn.execute(
        "UPDATE selection_tasks SET status=?, phase=?, updated_at=?, recovery_required=? WHERE task_id=?",
        (status, status, at or utc_now(), 1 if status == "RECOVERY_REQUIRED" else 0, task_id),
    )
    add_event(
        conn,
        {
            "taskId": task_id,
            "status": status,
            "phase": status,
            "message": reason,
            "source": "selection-module.control",
            "evidence": {"release": "module-owned runtime closeout requested"},
            "nextAction": "查看任务状态或请求恢复。",
            "at": at or utc_now(),
        },
    )
    conn.commit()
    return {"ok": True, "taskId": task_id, "status": status, "reason": reason}


def save_candidate(conn, record):
    conn.execute(
        """
        INSERT OR REPLACE INTO selection_candidates(snapshot_id, task_id, source, source_at, item_count, redacted_summary_json, created_at)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record["snapshotId"],
            record["taskId"],
            record.get("source"),
            record.get("sourceAt"),
            int(record.get("itemCount") or 0),
            dump_json(record.get("summary")),
            record.get("createdAt") or utc_now(),
        ),
    )
    conn.execute(
        "INSERT INTO selection_audits(task_id, event_type, redacted_payload_json, created_at) VALUES(?, ?, ?, ?)",
        (record["taskId"], "candidate_snapshot_saved", dump_json(record), utc_now()),
    )
    conn.commit()
    return {"ok": True, "snapshotId": record["snapshotId"]}


def save_action(conn, record):
    conn.execute(
        """
        INSERT OR REPLACE INTO selection_actions(action_record_id, task_id, action_id, idempotency_key, external_ref, status, readback_at, redacted_result_json, created_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            record["actionRecordId"],
            record["taskId"],
            record["actionId"],
            record.get("idempotencyKey"),
            record.get("externalRef"),
            record["status"],
            record.get("readbackAt"),
            dump_json(record.get("result")),
            record.get("createdAt") or utc_now(),
        ),
    )
    conn.execute(
        "INSERT INTO selection_audits(task_id, event_type, redacted_payload_json, created_at) VALUES(?, ?, ?, ?)",
        (record["taskId"], "selection_action_saved", dump_json(record), utc_now()),
    )
    conn.commit()
    return {"ok": True, "actionRecordId": record["actionRecordId"]}


def list_recoverable(conn, task_id=None):
    if task_id:
        rows = conn.execute(
            "SELECT * FROM selection_recoveries WHERE task_id=? ORDER BY recovery_id DESC",
            (task_id,),
        ).fetchall()
    else:
        rows = conn.execute(
            "SELECT * FROM selection_recoveries WHERE status='OPEN' ORDER BY recovery_id DESC"
        ).fetchall()
    return {"ok": True, "status": "RECOVERY_LISTED", "records": [dict(x) for x in rows]}


def diagnostics(conn):
    return {
        "ok": True,
        "status": "SQLITE_DIAGNOSTICS",
        "integrity": conn.execute("PRAGMA integrity_check").fetchone()[0],
        "schemaVersion": conn.execute("SELECT max(version) FROM schema_migrations").fetchone()[0],
        "tables": [
            row[0]
            for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        ],
        "taskCount": conn.execute("SELECT count(*) FROM selection_tasks").fetchone()[0],
        "eventCount": conn.execute("SELECT count(*) FROM selection_events").fetchone()[0],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    args = parser.parse_args()
    payload = sys.stdin.read()
    if payload.startswith("\ufeff"):
        payload = payload.lstrip("\ufeff")
    command = json.loads(payload)
    with connect(args.db) as conn:
        action = command.get("action")
        if action == "init":
            result = init(conn)
        elif action == "save_task":
            result = save_task(conn, command["record"])
        elif action == "add_event":
            result = add_event(conn, command["record"])
        elif action == "get_task":
            result = get_task(conn, command["taskId"])
        elif action == "set_terminal":
            result = set_terminal(conn, command["taskId"], command["status"], command.get("reason"), command.get("at"))
        elif action == "list_recoverable":
            result = list_recoverable(conn, command.get("taskId"))
        elif action == "diagnostics":
            result = diagnostics(conn)
        elif action == "save_candidate":
            result = save_candidate(conn, command["record"])
        elif action == "save_action":
            result = save_action(conn, command["record"])
        else:
            raise ValueError(f"unknown action: {action}")
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
