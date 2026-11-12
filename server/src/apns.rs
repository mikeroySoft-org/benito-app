//! ActivityKit Live Activity push via APNs (token-based updates).
//!
//! Phase 1: sandbox path only on the client; server routes each token to
//! api.sandbox.push.apple.com or api.push.apple.com from the stored `apns_env`.
//!
//! When `APNS_KEY_PATH` / `APNS_KEY_ID` / `APNS_TEAM_ID` / `APNS_TOPIC` are unset,
//! every send is a no-op (WebSocket sync still works). Never log the private key.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use jsonwebtoken::{encode, Algorithm, EncodingKey, Header};
use rusqlite::params;
use serde::Serialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::db::Db;

const JWT_TTL: Duration = Duration::from_secs(50 * 60);
const SANDBOX_HOST: &str = "https://api.sandbox.push.apple.com";
const PRODUCTION_HOST: &str = "https://api.push.apple.com";

/// Cleared `BenitoActivityAttributes.ContentState` as ActivityKit would JSON-encode it:
/// optionals omitted (encodeIfPresent), `timerPausedSeconds` = 0. Dates would be
/// seconds-since-2001 if present; the cleared end payload has none.
pub fn end_content_state() -> Value {
    json!({ "timerPausedSeconds": 0 })
}

/// APNs Live Activity `end` payload matching local `LiveActivitySync.end`:
/// cleared ContentState + immediate dismissal (`dismissal-date` in the past).
pub fn end_payload(now_unix: i64) -> Value {
    json!({
        "aps": {
            "timestamp": now_unix,
            "event": "end",
            "dismissal-date": 0,
            "content-state": end_content_state(),
        }
    })
}

#[derive(Clone)]
pub struct ApnsClient {
    inner: Option<Configured>,
}

#[derive(Clone)]
struct Configured {
    key_pem: String,
    key_id: String,
    team_id: String,
    topic: String,
    http: reqwest::Client,
    jwt: std::sync::Arc<Mutex<Option<(String, Instant)>>>,
}

#[derive(Debug, Serialize)]
struct ApnsClaims {
    iss: String,
    iat: u64,
}

#[derive(Debug, Clone)]
pub struct StoredToken {
    pub token: String,
    pub client_id: String,
    pub apns_env: String,
}

impl ApnsClient {
    /// Build from env. Missing any of the four vars → disabled (no-op sends).
    pub fn from_env() -> Self {
        let key_path = std::env::var("APNS_KEY_PATH")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let key_id = std::env::var("APNS_KEY_ID")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let team_id = std::env::var("APNS_TEAM_ID")
            .ok()
            .filter(|s| !s.trim().is_empty());
        let topic = std::env::var("APNS_TOPIC")
            .ok()
            .filter(|s| !s.trim().is_empty());

        match (key_path, key_id, team_id, topic) {
            (Some(path), Some(key_id), Some(team_id), Some(topic)) => {
                match std::fs::read_to_string(&path) {
                    Ok(key_pem) if !key_pem.trim().is_empty() => {
                        let http = reqwest::Client::builder()
                            .timeout(Duration::from_secs(15))
                            .build()
                            .expect("reqwest client");
                        tracing::info!(
                            key_id = %key_id,
                            team_id = %team_id,
                            topic = %topic,
                            "APNs Live Activity push enabled"
                        );
                        Self {
                            inner: Some(Configured {
                                key_pem,
                                key_id,
                                team_id,
                                topic,
                                http,
                                jwt: std::sync::Arc::new(Mutex::new(None)),
                            }),
                        }
                    }
                    Ok(_) => {
                        tracing::warn!(
                            path = %path,
                            "APNS_KEY_PATH is empty; Live Activity push disabled"
                        );
                        Self { inner: None }
                    }
                    Err(e) => {
                        tracing::warn!(
                            path = %path,
                            error = %e,
                            "APNS_KEY_PATH unreadable; Live Activity push disabled"
                        );
                        Self { inner: None }
                    }
                }
            }
            _ => {
                tracing::info!(
                    "APNs Live Activity push disabled (set APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC to enable)"
                );
                Self { inner: None }
            }
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Fan-out an `end` push to every Live Activity update token in the family,
    /// skipping the originating device's `client_id` (local end already ran there).
    pub async fn fanout_timer_end(&self, db: &Db, family_id: Uuid, skip_client_id: Option<&str>) {
        let Some(cfg) = self.inner.clone() else {
            return;
        };
        let tokens = match load_family_tokens(db, family_id) {
            Ok(t) => t,
            Err(e) => {
                tracing::error!(error = %e, "failed to load live_activity_tokens");
                return;
            }
        };
        let now = unix_now();
        let payload = end_payload(now);
        let body = match serde_json::to_vec(&payload) {
            Ok(b) => b,
            Err(e) => {
                tracing::error!(error = %e, "serialize APNs end payload");
                return;
            }
        };

        for tok in tokens {
            if let Some(skip) = skip_client_id {
                if tok.client_id == skip {
                    continue;
                }
            }
            if let Err(e) = cfg.send_end(&tok, &body).await {
                tracing::warn!(
                    client_id = %tok.client_id,
                    apns_env = %tok.apns_env,
                    error = %e,
                    "APNs Live Activity end push failed"
                );
            }
        }
    }
}

impl Configured {
    async fn send_end(&self, tok: &StoredToken, body: &[u8]) -> Result<(), String> {
        let host = match tok.apns_env.as_str() {
            "production" => PRODUCTION_HOST,
            _ => SANDBOX_HOST,
        };
        let url = format!("{host}/3/device/{}", tok.token);
        let jwt = self.bearer_jwt()?;
        let res = self
            .http
            .post(&url)
            .header("authorization", format!("bearer {jwt}"))
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "liveactivity")
            .header("apns-priority", "10")
            .header("content-type", "application/json")
            .body(body.to_vec())
            .send()
            .await
            .map_err(|e| format!("transport: {e}"))?;
        let status = res.status();
        if status.is_success() {
            tracing::info!(
                client_id = %tok.client_id,
                apns_env = %tok.apns_env,
                "APNs Live Activity end delivered"
            );
            return Ok(());
        }
        let text = res.text().await.unwrap_or_default();
        Err(format!("HTTP {status}: {text}"))
    }

    fn bearer_jwt(&self) -> Result<String, String> {
        let mut guard = self
            .jwt
            .lock()
            .map_err(|_| "jwt lock poisoned".to_string())?;
        if let Some((token, at)) = guard.as_ref() {
            if at.elapsed() < JWT_TTL {
                return Ok(token.clone());
            }
        }
        let iat = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_secs();
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.clone());
        let claims = ApnsClaims {
            iss: self.team_id.clone(),
            iat,
        };
        let key = EncodingKey::from_ec_pem(self.key_pem.as_bytes())
            .map_err(|e| format!("APNs key PEM: {e}"))?;
        let token = encode(&header, &claims, &key).map_err(|e| format!("JWT encode: {e}"))?;
        *guard = Some((token.clone(), Instant::now()));
        Ok(token)
    }
}

fn unix_now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

pub fn load_family_tokens(db: &Db, family_id: Uuid) -> Result<Vec<StoredToken>, String> {
    let conn = db.lock().map_err(|_| "db lock".to_string())?;
    let mut stmt = conn
        .prepare("SELECT token, client_id, apns_env FROM live_activity_tokens WHERE family_id = ?1")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(params![family_id.to_string()], |r| {
            Ok(StoredToken {
                token: r.get(0)?,
                client_id: r.get(1)?,
                apns_env: r.get(2)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row.map_err(|e| e.to_string())?);
    }
    Ok(out)
}

/// Validate a hex ActivityKit push token (32+ bytes → 64+ hex chars).
pub fn validate_token_hex(token: &str) -> Result<(), String> {
    let t = token.trim();
    if t.len() < 64 || !t.len().is_multiple_of(2) {
        return Err("token must be hex of at least 32 bytes".into());
    }
    if !t.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("token must be lowercase/uppercase hex".into());
    }
    Ok(())
}

pub fn normalize_apns_env(env: &str) -> Result<&'static str, String> {
    match env.trim().to_ascii_lowercase().as_str() {
        "sandbox" | "development" => Ok("sandbox"),
        "production" | "prod" => Ok("production"),
        other => Err(format!(
            "apns_env must be sandbox or production, got {other}"
        )),
    }
}

#[allow(dead_code)]
pub fn _key_path_hint() -> Option<PathBuf> {
    std::env::var_os("APNS_KEY_PATH").map(PathBuf::from)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn end_payload_matches_cleared_content_state() {
        let p = end_payload(1_700_000_000);
        let aps = &p["aps"];
        assert_eq!(aps["event"], "end");
        assert_eq!(aps["dismissal-date"], 0);
        assert_eq!(aps["timestamp"], 1_700_000_000);
        assert_eq!(aps["content-state"]["timerPausedSeconds"], 0);
        // Optionals omitted — matches Swift encodeIfPresent of ContentState().
        assert!(aps["content-state"].get("timerKind").is_none());
        assert!(aps["content-state"].get("timerStartedAt").is_none());
        assert!(aps["content-state"].get("lastFeedAt").is_none());
    }

    #[test]
    fn validate_token_hex_ok() {
        let hex = "a".repeat(64);
        assert!(validate_token_hex(&hex).is_ok());
    }

    #[test]
    fn normalize_apns_env_aliases() {
        assert_eq!(normalize_apns_env("sandbox").unwrap(), "sandbox");
        assert_eq!(normalize_apns_env("development").unwrap(), "sandbox");
        assert_eq!(normalize_apns_env("production").unwrap(), "production");
    }
}
