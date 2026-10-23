-- Passwordless sharing: per-device keys, expiring single-use family invites, server identity.
-- Additive only (new tables). Column additions live in db.rs behind has_column checks.
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    -- base64 (standard) X9.63 uncompressed P-256 public key (65 bytes).
    public_key TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    model TEXT,
    created_at TEXT NOT NULL,
    last_seen_at TEXT,
    -- Highest signed timestamp accepted; a signature must use a newer one (replay guard).
    last_auth_ts INTEGER NOT NULL DEFAULT 0,
    revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id);

CREATE TABLE IF NOT EXISTS family_invites (
    id TEXT PRIMARY KEY NOT NULL,
    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    -- hex SHA-256 of the invite secret; the secret itself is only ever in the invite link.
    secret_hash TEXT NOT NULL,
    role TEXT NOT NULL DEFAULT 'parent',
    -- Caregiver access length from redemption (NULL = no end).
    access_hours INTEGER,
    label TEXT,
    created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    used_by TEXT REFERENCES users(id) ON DELETE SET NULL,
    revoked_at TEXT
);

CREATE INDEX IF NOT EXISTS idx_family_invites_family ON family_invites(family_id);

CREATE TABLE IF NOT EXISTS server_meta (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
