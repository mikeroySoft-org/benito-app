//! Register / delete ActivityKit Live Activity update push tokens.

use axum::{
    extract::{Query, State},
    http::HeaderMap,
    Json,
};
use chrono::Utc;
use rusqlite::params;
use serde::Deserialize;
use serde_json::{json, Value};
use uuid::Uuid;

use crate::apns::{normalize_apns_env, validate_token_hex};
use crate::auth::{AuthError, AuthUser};
use crate::AppState;

fn client_id_from(headers: &HeaderMap) -> Option<String> {
    headers
        .get("x-client-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn family_id_for_user(conn: &rusqlite::Connection, user_id: Uuid) -> Result<Uuid, AuthError> {
    let id: String = conn
        .query_row(
            "SELECT family_id FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user_id.to_string()],
            |r| r.get(0),
        )
        .map_err(|_| AuthError::BadRequest("not in a family".into()))?;
    Uuid::parse_str(&id).map_err(|_| AuthError::Internal)
}

#[derive(Debug, Deserialize)]
pub struct RegisterTokenBody {
    pub token: String,
    pub apns_env: String,
    pub activity_id: Option<String>,
}

/// `POST /live-activity/tokens` — upsert this device's ActivityKit update token.
pub async fn register_token(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    headers: HeaderMap,
    Json(body): Json<RegisterTokenBody>,
) -> Result<Json<Value>, AuthError> {
    let client_id = client_id_from(&headers)
        .ok_or_else(|| AuthError::BadRequest("X-Client-Id required".into()))?;
    validate_token_hex(&body.token).map_err(AuthError::BadRequest)?;
    let apns_env = normalize_apns_env(&body.apns_env).map_err(AuthError::BadRequest)?;
    let token = body.token.trim().to_ascii_lowercase();
    let activity_id = body
        .activity_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());
    let now = Utc::now().to_rfc3339();

    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = family_id_for_user(&conn, user.id)?;

    // One row per device (client_id) and per token value.
    conn.execute(
        "DELETE FROM live_activity_tokens WHERE client_id = ?1 OR token = ?2",
        params![client_id, token],
    )
    .map_err(|_| AuthError::Internal)?;
    conn.execute(
        "INSERT INTO live_activity_tokens (token, family_id, user_id, client_id, activity_id, apns_env, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            token,
            family_id.to_string(),
            user.id.to_string(),
            client_id,
            activity_id,
            apns_env,
            now,
        ],
    )
    .map_err(|_| AuthError::Internal)?;

    Ok(Json(json!({
        "ok": true,
        "apns_env": apns_env,
        "apns_enabled": state.apns.is_enabled(),
    })))
}

#[derive(Debug, Deserialize, Default)]
pub struct DeleteTokenQuery {
    pub token: Option<String>,
}

/// `DELETE /live-activity/tokens` — drop this device's tokens (sign-out), or `?token=` one.
pub async fn delete_tokens(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    headers: HeaderMap,
    Query(q): Query<DeleteTokenQuery>,
) -> Result<Json<Value>, AuthError> {
    let client_id = client_id_from(&headers)
        .ok_or_else(|| AuthError::BadRequest("X-Client-Id required".into()))?;
    let specific = q
        .token
        .map(|t| t.trim().to_ascii_lowercase())
        .filter(|t| !t.is_empty());

    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let deleted = if let Some(token) = specific {
        conn.execute(
            "DELETE FROM live_activity_tokens WHERE user_id = ?1 AND token = ?2",
            params![user.id.to_string(), token],
        )
        .map_err(|_| AuthError::Internal)?
    } else {
        conn.execute(
            "DELETE FROM live_activity_tokens WHERE user_id = ?1 AND client_id = ?2",
            params![user.id.to_string(), client_id],
        )
        .map_err(|_| AuthError::Internal)?
    };

    Ok(Json(json!({ "ok": true, "deleted": deleted })))
}
