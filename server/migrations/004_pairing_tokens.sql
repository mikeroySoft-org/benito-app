-- Short-lived, single-use tokens for proximity partner pairing (SharePlay/AirDrop).
-- Minted by a family member (`POST /families/pairing-tokens`), redeemed once by the joining
-- parent (`POST /families/pair`). Stored raw, like `sessions.token`.
CREATE TABLE IF NOT EXISTS pairing_tokens (
    token TEXT PRIMARY KEY NOT NULL,
    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    used_at TEXT,
    used_by TEXT REFERENCES users(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_pairing_tokens_family ON pairing_tokens(family_id);
