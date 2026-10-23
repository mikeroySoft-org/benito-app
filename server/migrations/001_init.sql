-- Benito schema (SPEC sketch + sessions for auth)
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS families (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL,
    invite_code TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS family_members (
    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'parent',
    joined_at TEXT NOT NULL,
    PRIMARY KEY (family_id, user_id)
);

CREATE TABLE IF NOT EXISTS children (
    id TEXT PRIMARY KEY NOT NULL,
    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    birthdate TEXT,
    sex TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
    id TEXT PRIMARY KEY NOT NULL,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    type TEXT NOT NULL,
    subtype TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    amount_value REAL,
    amount_unit TEXT,
    side TEXT,
    notes TEXT,
    payload_json TEXT,
    created_by TEXT NOT NULL REFERENCES users(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_events_child_started ON events(child_id, started_at DESC);
CREATE INDEX IF NOT EXISTS idx_events_type ON events(child_id, type);

CREATE TABLE IF NOT EXISTS timers (
    id TEXT PRIMARY KEY NOT NULL,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    started_at TEXT NOT NULL,
    started_by TEXT NOT NULL REFERENCES users(id),
    state TEXT NOT NULL DEFAULT 'running',
    stopped_at TEXT,
    updated_at TEXT NOT NULL,
    side TEXT
);

CREATE INDEX IF NOT EXISTS idx_timers_child_state ON timers(child_id, state);

CREATE TABLE IF NOT EXISTS reminders (
    id TEXT PRIMARY KEY NOT NULL,
    child_id TEXT NOT NULL REFERENCES children(id) ON DELETE CASCADE,
    kind TEXT NOT NULL,
    rule TEXT NOT NULL,
    next_fire_at TEXT,
    created_at TEXT NOT NULL
);

-- Local-device reminders are v1; this table is a hook for future server-side / APNs
CREATE TABLE IF NOT EXISTS sessions (
    token TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions(user_id);
