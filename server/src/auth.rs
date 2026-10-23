use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::{
    extract::FromRequestParts,
    http::{header::AUTHORIZATION, request::Parts, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use chrono::{Duration, Utc};
use rand::RngCore;
use rusqlite::params;
use serde_json::json;
use uuid::Uuid;

use crate::db::Db;
use crate::models::User;

pub fn hash_password(password: &str) -> Result<String, AuthError> {
    let salt = SaltString::generate(&mut rand::thread_rng());
    let hash = Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|_| AuthError::Internal)?
        .to_string();
    Ok(hash)
}

pub fn verify_password(password: &str, hash: &str) -> Result<bool, AuthError> {
    // Passwordless (device-key) accounts store a non-PHC marker: never a match.
    let Ok(parsed) = PasswordHash::new(hash) else {
        return Ok(false);
    };
    Ok(Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok())
}

pub fn new_session_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    hex::encode(bytes)
}

pub fn create_session(db: &Db, user_id: Uuid) -> Result<String, AuthError> {
    let conn = db.lock().map_err(|_| AuthError::Internal)?;
    insert_session(&conn, user_id, None)
}

/// Inserts a session row on an already-locked connection (or inside a transaction).
/// `device_id` links device-key sessions so revoking the device ends them.
pub fn insert_session(
    conn: &rusqlite::Connection,
    user_id: Uuid,
    device_id: Option<&str>,
) -> Result<String, AuthError> {
    let token = new_session_token();
    let now = Utc::now();
    let expires = now + Duration::days(SESSION_LIFETIME_DAYS);
    conn.execute(
        "INSERT INTO sessions (token, user_id, created_at, expires_at, device_id) VALUES (?1, ?2, ?3, ?4, ?5)",
        params![token, user_id.to_string(), now.to_rfc3339(), expires.to_rfc3339(), device_id],
    )
    .map_err(|_| AuthError::Internal)?;
    Ok(token)
}

/// Ends a user's access entirely: memberships, sessions, and device keys.
pub fn revoke_user_access(
    conn: &rusqlite::Connection,
    user_id: &str,
    family_id: Option<&str>,
) -> rusqlite::Result<()> {
    let now = Utc::now().to_rfc3339();
    match family_id {
        Some(f) => conn.execute(
            "DELETE FROM family_members WHERE user_id = ?1 AND family_id = ?2",
            params![user_id, f],
        )?,
        None => conn.execute(
            "DELETE FROM family_members WHERE user_id = ?1",
            params![user_id],
        )?,
    };
    conn.execute("DELETE FROM sessions WHERE user_id = ?1", params![user_id])?;
    conn.execute(
        "UPDATE devices SET revoked_at = ?2 WHERE user_id = ?1 AND revoked_at IS NULL",
        params![user_id, now],
    )?;
    Ok(())
}

/// Sessions last this long from creation, and are pushed back out to this on renewal.
const SESSION_LIFETIME_DAYS: i64 = 30;
/// A session used with less than this left is renewed (sliding expiry for active users).
const SESSION_RENEW_BELOW_DAYS: i64 = 15;

pub fn user_from_token(db: &Db, token: &str) -> Result<User, AuthError> {
    let conn = db.lock().map_err(|_| AuthError::Internal)?;
    let now = Utc::now();
    let (user, expires_at) = conn
        .query_row(
            "SELECT u.id, u.name, u.email, u.created_at, s.expires_at
             FROM sessions s
             JOIN users u ON u.id = s.user_id
             WHERE s.token = ?1 AND s.expires_at > ?2",
            params![token, now.to_rfc3339()],
            |r| {
                let user = User {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    name: r.get(1)?,
                    email: r.get(2)?,
                    created_at: chrono::DateTime::parse_from_rfc3339(&r.get::<_, String>(3)?)
                        .map(|d| d.with_timezone(&Utc))
                        .map_err(|e| {
                            rusqlite::Error::FromSqlConversionFailure(
                                3,
                                rusqlite::types::Type::Text,
                                Box::new(e),
                            )
                        })?,
                };
                let expires_at = chrono::DateTime::parse_from_rfc3339(&r.get::<_, String>(4)?)
                    .map(|d| d.with_timezone(&Utc))
                    .map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            4,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?;
                Ok((user, expires_at))
            },
        )
        .map_err(|_| AuthError::Unauthorized)?;

    // Caregiver access with an end date: once it passes, the membership, sessions and device
    // keys go away and this request is rejected.
    let expired_membership: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM family_members
             WHERE user_id = ?1 AND expires_at IS NOT NULL AND expires_at <= ?2 LIMIT 1",
            params![user.id.to_string(), now.to_rfc3339()],
            |r| r.get(0),
        )
        .ok();
    if expired_membership.is_some() {
        revoke_user_access(&conn, &user.id.to_string(), None).map_err(|_| AuthError::Internal)?;
        return Err(AuthError::Unauthorized);
    }

    // "Last seen" for the Sharing list; throttled to one write a minute per device.
    let _ = conn.execute(
        "UPDATE devices SET last_seen_at = ?2
         WHERE id = (SELECT device_id FROM sessions WHERE token = ?1)
           AND (last_seen_at IS NULL OR last_seen_at < ?3)",
        params![
            token,
            now.to_rfc3339(),
            (now - Duration::seconds(60)).to_rfc3339()
        ],
    );

    // Sliding expiry: only live sessions reach here (the query filters expired ones), so an
    // active user's token is pushed back out before it can lapse.
    if expires_at - now < Duration::days(SESSION_RENEW_BELOW_DAYS) {
        conn.execute(
            "UPDATE sessions SET expires_at = ?2 WHERE token = ?1",
            params![
                token,
                (now + Duration::days(SESSION_LIFETIME_DAYS)).to_rfc3339()
            ],
        )
        .map_err(|_| AuthError::Internal)?;
    }
    Ok(user)
}

#[derive(Clone)]
pub struct AuthUser(pub User);

impl FromRequestParts<crate::AppState> for AuthUser {
    type Rejection = AuthError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &crate::AppState,
    ) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(AuthError::Unauthorized)?;
        let token = header
            .strip_prefix("Bearer ")
            .ok_or(AuthError::Unauthorized)?;
        let user = user_from_token(&state.db, token)?;
        Ok(AuthUser(user))
    }
}

#[derive(Debug)]
pub enum AuthError {
    Unauthorized,
    BadRequest(String),
    Conflict(String),
    Forbidden(String),
    NotFound(String),
    Internal,
}

impl IntoResponse for AuthError {
    fn into_response(self) -> Response {
        let (status, msg) = match &self {
            AuthError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".into()),
            AuthError::BadRequest(m) => (StatusCode::BAD_REQUEST, m.clone()),
            AuthError::Conflict(m) => (StatusCode::CONFLICT, m.clone()),
            AuthError::Forbidden(m) => (StatusCode::FORBIDDEN, m.clone()),
            AuthError::NotFound(m) => (StatusCode::NOT_FOUND, m.clone()),
            AuthError::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal error".into()),
        };
        (status, Json(json!({ "error": msg }))).into_response()
    }
}

pub fn invite_code() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    (0..8)
        .map(|_| ALPHABET[rng.next_u32() as usize % ALPHABET.len()] as char)
        .collect()
}
