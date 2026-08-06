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

INSERT OR IGNORE INTO schema_migrations(version, applied_at)
VALUES(1, datetime('now'));
