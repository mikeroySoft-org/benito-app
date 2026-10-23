-- ActivityKit Live Activity update push tokens (one per device / X-Client-Id).
-- apns_env is 'sandbox' (Xcode / development) or 'production' (TestFlight / App Store).
CREATE TABLE IF NOT EXISTS live_activity_tokens (
    token TEXT PRIMARY KEY NOT NULL,
    family_id TEXT NOT NULL REFERENCES families(id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    client_id TEXT NOT NULL,
    activity_id TEXT,
    apns_env TEXT NOT NULL CHECK (apns_env IN ('sandbox', 'production')),
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_live_activity_tokens_client
    ON live_activity_tokens(client_id);

CREATE INDEX IF NOT EXISTS idx_live_activity_tokens_family
    ON live_activity_tokens(family_id);
