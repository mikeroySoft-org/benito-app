//! Passwordless sharing: device keys, family members, expiring invites, server identity.
//! See docs/plans/oss-onboarding-sharing.md §3.
use axum::{
    extract::{Path, State},
    http::{header::AUTHORIZATION, HeaderMap},
    Json,
};
use chrono::{DateTime, Duration, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::auth::{insert_session, revoke_user_access, user_from_token, AuthError, AuthUser};
use crate::device_auth::{
    auth_message, canonical_public_key, digests_match, hash_secret, new_invite_secret,
    parse_public_key, synthetic_email, verify, MAX_CLOCK_SKEW_SECS, NO_PASSWORD_HASH,
};
use crate::models::{Family, User};
use crate::sync::SyncEnvelope;
use crate::AppState;

pub const ROLE_PARENT: &str = "parent";
pub const ROLE_CAREGIVER: &str = "caregiver";

/// Invites outlive a text message sitting unread overnight, but not much longer.
const INVITE_DEFAULT_HOURS: i64 = 72;
const INVITE_MAX_HOURS: i64 = 24 * 7;
/// Caregiver access cap (a long-term nanny can be re-invited).
const ACCESS_MAX_HOURS: i64 = 24 * 365;

fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

fn clean_name(raw: &str, fallback: &str, max: usize) -> String {
    let trimmed: String = raw.trim().chars().take(max).collect();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed
    }
}

/// `(family_id, role)` of the caller's membership, if any.
pub fn membership(conn: &Connection, user_id: &str) -> Result<Option<(String, String)>, AuthError> {
    conn.query_row(
        "SELECT family_id, role FROM family_members WHERE user_id = ?1 LIMIT 1",
        params![user_id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .map_err(|_| AuthError::Internal)
}

/// The caller's family id when they are a parent (invites, revoke, rotate are parent-only).
pub fn require_parent(conn: &Connection, user_id: &str) -> Result<String, AuthError> {
    match membership(conn, user_id)? {
        Some((family_id, role)) if role == ROLE_PARENT => Ok(family_id),
        Some(_) => Err(AuthError::Forbidden(
            "only parents can manage sharing".into(),
        )),
        None => Err(AuthError::NotFound("no family".into())),
    }
}

fn server_id(conn: &Connection) -> String {
    conn.query_row(
        "SELECT value FROM server_meta WHERE key = 'server_id'",
        [],
        |r| r.get(0),
    )
    .unwrap_or_default()
}

/// `BENITO_PUBLIC_URLS`: comma-separated origins clients can use (LAN first, then tailnet / WAN).
pub fn advertised_urls() -> Vec<String> {
    std::env::var("BENITO_PUBLIC_URLS")
        .unwrap_or_default()
        .split(',')
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| s.starts_with("http://") || s.starts_with("https://"))
        .collect()
}

fn load_user(conn: &Connection, user_id: &str) -> Result<User, AuthError> {
    conn.query_row(
        "SELECT id, name, email, created_at FROM users WHERE id = ?1",
        params![user_id],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        },
    )
    .map_err(|_| AuthError::Internal)
    .and_then(|(id, name, email, created_at)| {
        Ok(User {
            id: Uuid::parse_str(&id).map_err(|_| AuthError::Internal)?,
            name,
            email,
            created_at: parse_time(&created_at).ok_or(AuthError::Internal)?,
        })
    })
}

fn load_family(conn: &Connection, family_id: &str) -> Result<Family, AuthError> {
    conn.query_row(
        "SELECT id, name, invite_code, created_at FROM families WHERE id = ?1",
        params![family_id],
        |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        },
    )
    .map_err(|_| AuthError::NotFound("family not found".into()))
    .and_then(|(id, name, invite_code, created_at)| {
        Ok(Family {
            id: Uuid::parse_str(&id).map_err(|_| AuthError::Internal)?,
            name,
            invite_code,
            created_at: parse_time(&created_at).ok_or(AuthError::Internal)?,
        })
    })
}

/// Inserts (or, for the same user, reuses) a device row. A key already bound to another
/// account is a conflict: one physical key belongs to one person.
fn upsert_device(
    conn: &Connection,
    user_id: &str,
    public_key: &str,
    name: &str,
    model: Option<&str>,
) -> Result<String, AuthError> {
    let key = parse_public_key(public_key)
        .ok_or_else(|| AuthError::BadRequest("public_key must be base64 X9.63 P-256".into()))?;
    let canonical = canonical_public_key(&key);
    let existing: Option<(String, String, Option<String>)> = conn
        .query_row(
            "SELECT id, user_id, revoked_at FROM devices WHERE public_key = ?1",
            params![canonical],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;
    let now = Utc::now().to_rfc3339();
    if let Some((id, owner, revoked_at)) = existing {
        if owner != user_id {
            return Err(AuthError::Conflict(
                "device key belongs to another account".into(),
            ));
        }
        if revoked_at.is_some() {
            return Err(AuthError::Forbidden(
                "device was removed; generate a new key".into(),
            ));
        }
        conn.execute(
            "UPDATE devices SET name = ?2, model = ?3, last_seen_at = ?4 WHERE id = ?1",
            params![id, name, model, now],
        )
        .map_err(|_| AuthError::Internal)?;
        return Ok(id);
    }
    let id = Uuid::new_v4().to_string();
    conn.execute(
        "INSERT INTO devices (id, user_id, public_key, name, model, created_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)",
        params![id, user_id, canonical, name, model, now],
    )
    .map_err(|_| AuthError::Internal)?;
    Ok(id)
}

// MARK: - Server identity

pub async fn server_info(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    Ok(Json(json!({
        "service": "benito-server",
        "version": env!("CARGO_PKG_VERSION"),
        "server_id": server_id(&conn),
        "advertised_urls": advertised_urls(),
        "features": ["device_auth", "invites", "caregiver_role"],
    })))
}

// MARK: - Device keys

#[derive(Debug, Deserialize)]
pub struct DeviceKeyRequest {
    pub public_key: String,
    #[serde(default)]
    pub device_name: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DeviceSignupRequest {
    pub name: String,
    #[serde(flatten)]
    pub device: DeviceKeyRequest,
}

#[derive(Debug, Serialize)]
pub struct DeviceAuthResponse {
    pub token: String,
    pub user: User,
    pub device_id: String,
}

/// `POST /auth/device/signup`: passwordless account bound to this device's key.
pub async fn device_signup(
    State(state): State<AppState>,
    Json(body): Json<DeviceSignupRequest>,
) -> Result<Json<DeviceAuthResponse>, AuthError> {
    let mut conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let tx = conn.transaction().map_err(|_| AuthError::Internal)?;
    let user_id = Uuid::new_v4();
    let now = Utc::now().to_rfc3339();
    let name = clean_name(&body.name, "Parent", 60);
    tx.execute(
        "INSERT INTO users (id, name, email, password_hash, created_at) VALUES (?1,?2,?3,?4,?5)",
        params![
            user_id.to_string(),
            name,
            synthetic_email(&user_id.to_string()),
            NO_PASSWORD_HASH,
            now
        ],
    )
    .map_err(|_| AuthError::Internal)?;
    let device_name = clean_name(
        body.device.device_name.as_deref().unwrap_or(""),
        "iPhone",
        60,
    );
    let device_id = upsert_device(
        &tx,
        &user_id.to_string(),
        &body.device.public_key,
        &device_name,
        body.device.model.as_deref(),
    )?;
    let token = insert_session(&tx, user_id, Some(&device_id))?;
    let user = load_user(&tx, &user_id.to_string())?;
    tx.commit().map_err(|_| AuthError::Internal)?;
    Ok(Json(DeviceAuthResponse {
        token,
        user,
        device_id,
    }))
}

/// `POST /devices`: attach this device's key to the signed-in account (password accounts
/// migrate this way, so a lapsed session renews with the key instead of the password).
pub async fn register_device(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Json(body): Json<DeviceKeyRequest>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let device_name = clean_name(body.device_name.as_deref().unwrap_or(""), "iPhone", 60);
    let id = upsert_device(
        &conn,
        &user.id.to_string(),
        &body.public_key,
        &device_name,
        body.model.as_deref(),
    )?;
    Ok(Json(json!({ "device_id": id })))
}

#[derive(Debug, Deserialize)]
pub struct DeviceSessionRequest {
    pub device_id: String,
    pub timestamp: i64,
    pub signature: String,
}

/// `POST /auth/device/session`: signed timestamp → bearer session.
pub async fn device_session(
    State(state): State<AppState>,
    Json(body): Json<DeviceSessionRequest>,
) -> Result<Json<DeviceAuthResponse>, AuthError> {
    let now = Utc::now();
    if (now.timestamp() - body.timestamp).abs() > MAX_CLOCK_SKEW_SECS {
        return Err(AuthError::BadRequest(
            "timestamp out of range; check the phone's clock".into(),
        ));
    }
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let (user_id, public_key, last_ts, revoked_at): (String, String, i64, Option<String>) = conn
        .query_row(
            "SELECT user_id, public_key, last_auth_ts, revoked_at FROM devices WHERE id = ?1",
            params![body.device_id],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|_| AuthError::Unauthorized)?;
    if revoked_at.is_some() || body.timestamp <= last_ts {
        return Err(AuthError::Unauthorized);
    }
    let key = parse_public_key(&public_key).ok_or(AuthError::Internal)?;
    if !verify(
        &key,
        auth_message(&body.device_id, body.timestamp).as_bytes(),
        &body.signature,
    ) {
        return Err(AuthError::Unauthorized);
    }
    // Compare-and-set guards the replay window against a concurrent identical request.
    let updated = conn
        .execute(
            "UPDATE devices SET last_auth_ts = ?2, last_seen_at = ?3 WHERE id = ?1 AND last_auth_ts < ?2",
            params![body.device_id, body.timestamp, now.to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
    if updated != 1 {
        return Err(AuthError::Unauthorized);
    }
    let uid = Uuid::parse_str(&user_id).map_err(|_| AuthError::Internal)?;
    let token = insert_session(&conn, uid, Some(&body.device_id))?;
    let user = load_user(&conn, &user_id)?;
    drop(conn);
    // Runs the caregiver-expiry check (and fails closed) before handing the token out.
    user_from_token(&state.db, &token)?;
    Ok(Json(DeviceAuthResponse {
        token,
        user,
        device_id: body.device_id,
    }))
}

// MARK: - Members

#[derive(Debug, Serialize)]
pub struct MemberDevice {
    pub id: String,
    pub name: String,
    pub model: Option<String>,
    pub created_at: String,
    pub last_seen_at: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Member {
    pub user_id: String,
    pub name: String,
    /// Real email for password accounts; omitted for passwordless (synthetic) ones.
    pub email: Option<String>,
    pub role: String,
    pub joined_at: String,
    pub access_expires_at: Option<String>,
    pub last_seen_at: Option<String>,
    pub is_you: bool,
    pub devices: Vec<MemberDevice>,
}

pub async fn list_members(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<Vec<Member>>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let me = user.id.to_string();
    let (family_id, _) =
        membership(&conn, &me)?.ok_or_else(|| AuthError::NotFound("no family".into()))?;
    let mut stmt = conn
        .prepare(
            "SELECT u.id, u.name, u.email, fm.role, fm.joined_at, fm.expires_at
             FROM family_members fm JOIN users u ON u.id = fm.user_id
             WHERE fm.family_id = ?1 ORDER BY fm.joined_at ASC",
        )
        .map_err(|_| AuthError::Internal)?;
    let rows: Vec<(String, String, String, String, String, Option<String>)> = stmt
        .query_map(params![family_id], |r| {
            Ok((
                r.get(0)?,
                r.get(1)?,
                r.get(2)?,
                r.get(3)?,
                r.get(4)?,
                r.get(5)?,
            ))
        })
        .map_err(|_| AuthError::Internal)?
        .filter_map(Result::ok)
        .collect();
    let mut dev_stmt = conn
        .prepare(
            "SELECT id, name, model, created_at, last_seen_at FROM devices
             WHERE user_id = ?1 AND revoked_at IS NULL ORDER BY created_at ASC",
        )
        .map_err(|_| AuthError::Internal)?;
    let mut members = Vec::with_capacity(rows.len());
    for (user_id, name, email, role, joined_at, expires_at) in rows {
        let devices: Vec<MemberDevice> = dev_stmt
            .query_map(params![user_id], |r| {
                Ok(MemberDevice {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    model: r.get(2)?,
                    created_at: r.get(3)?,
                    last_seen_at: r.get(4)?,
                })
            })
            .map_err(|_| AuthError::Internal)?
            .filter_map(Result::ok)
            .collect();
        let last_seen_at = devices.iter().filter_map(|d| d.last_seen_at.clone()).max();
        members.push(Member {
            is_you: user_id == me,
            email: (!crate::device_auth::is_synthetic_email(&email)).then_some(email),
            user_id,
            name,
            role,
            joined_at,
            access_expires_at: expires_at,
            last_seen_at,
            devices,
        });
    }
    Ok(Json(members))
}

/// `DELETE /families/members/{user_id}`: a parent removes someone (and all their devices).
pub async fn remove_member(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(target): Path<String>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = require_parent(&conn, &user.id.to_string())?;
    if target == user.id.to_string() {
        return Err(AuthError::BadRequest(
            "use Leave family to remove yourself".into(),
        ));
    }
    let is_member: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM family_members WHERE family_id = ?1 AND user_id = ?2",
            params![family_id, target],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;
    if is_member.is_none() {
        return Err(AuthError::NotFound("not a member of this family".into()));
    }
    revoke_user_access(&conn, &target, Some(&family_id)).map_err(|_| AuthError::Internal)?;
    drop(conn);
    if let Ok(fid) = Uuid::parse_str(&family_id) {
        state.sync.publish_to_family(
            fid,
            SyncEnvelope::new(
                "state",
                json!({ "action": "member_removed", "user_id": target }),
            ),
        );
    }
    Ok(Json(json!({ "removed": true })))
}

// MARK: - Invites

#[derive(Debug, Deserialize, Default)]
pub struct CreateInviteRequest {
    #[serde(default)]
    pub role: Option<String>,
    /// How long the link works (default 72 h, max 7 days).
    #[serde(default)]
    pub expires_in_hours: Option<i64>,
    /// Caregiver only: access length after joining (None = no end).
    #[serde(default)]
    pub access_hours: Option<i64>,
    #[serde(default)]
    pub label: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct InviteResponse {
    pub id: String,
    /// Only returned once, at creation. The server keeps a SHA-256 of it.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub secret: Option<String>,
    pub family_id: String,
    pub family_name: String,
    pub inviter_name: String,
    pub role: String,
    pub access_hours: Option<i64>,
    pub label: Option<String>,
    pub created_at: String,
    pub expires_at: String,
    pub server_id: String,
    pub endpoints: Vec<String>,
}

pub async fn create_invite(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    body: Option<Json<CreateInviteRequest>>,
) -> Result<Json<InviteResponse>, AuthError> {
    let body = body.map(|Json(b)| b).unwrap_or_default();
    let role = body.role.as_deref().unwrap_or(ROLE_PARENT).to_lowercase();
    if role != ROLE_PARENT && role != ROLE_CAREGIVER {
        return Err(AuthError::BadRequest(
            "role must be parent or caregiver".into(),
        ));
    }
    let hours = body.expires_in_hours.unwrap_or(INVITE_DEFAULT_HOURS);
    if !(1..=INVITE_MAX_HOURS).contains(&hours) {
        return Err(AuthError::BadRequest(format!(
            "expires_in_hours must be 1–{INVITE_MAX_HOURS}"
        )));
    }
    let access_hours = if role == ROLE_CAREGIVER {
        body.access_hours
    } else {
        None
    };
    if let Some(h) = access_hours {
        if !(1..=ACCESS_MAX_HOURS).contains(&h) {
            return Err(AuthError::BadRequest(format!(
                "access_hours must be 1–{ACCESS_MAX_HOURS}"
            )));
        }
    }
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = require_parent(&conn, &user.id.to_string())?;
    let family = load_family(&conn, &family_id)?;
    let id = Uuid::new_v4().to_string();
    let secret = new_invite_secret();
    let now = Utc::now();
    let expires = now + Duration::hours(hours);
    let label = body
        .label
        .map(|l| clean_name(&l, "", 60))
        .filter(|l| !l.is_empty());
    conn.execute(
        "INSERT INTO family_invites
         (id, family_id, secret_hash, role, access_hours, label, created_by, created_at, expires_at)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
        params![
            id,
            family_id,
            hash_secret(&secret),
            role,
            access_hours,
            label,
            user.id.to_string(),
            now.to_rfc3339(),
            expires.to_rfc3339()
        ],
    )
    .map_err(|_| AuthError::Internal)?;
    Ok(Json(InviteResponse {
        id,
        secret: Some(secret),
        family_id,
        family_name: family.name,
        inviter_name: user.name,
        role,
        access_hours,
        label,
        created_at: now.to_rfc3339(),
        expires_at: expires.to_rfc3339(),
        server_id: server_id(&conn),
        endpoints: advertised_urls(),
    }))
}

/// Pending (unused, unexpired, unrevoked) invites for the caller's family.
pub async fn list_invites(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<Vec<InviteResponse>>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = require_parent(&conn, &user.id.to_string())?;
    let family = load_family(&conn, &family_id)?;
    let sid = server_id(&conn);
    let mut stmt = conn
        .prepare(
            "SELECT i.id, i.role, i.access_hours, i.label, i.created_at, i.expires_at, u.name
             FROM family_invites i JOIN users u ON u.id = i.created_by
             WHERE i.family_id = ?1 AND i.used_at IS NULL AND i.revoked_at IS NULL AND i.expires_at > ?2
             ORDER BY i.created_at DESC",
        )
        .map_err(|_| AuthError::Internal)?;
    let invites = stmt
        .query_map(params![family_id, Utc::now().to_rfc3339()], |r| {
            Ok(InviteResponse {
                id: r.get(0)?,
                secret: None,
                family_id: family_id.clone(),
                family_name: family.name.clone(),
                role: r.get(1)?,
                access_hours: r.get(2)?,
                label: r.get(3)?,
                created_at: r.get(4)?,
                expires_at: r.get(5)?,
                inviter_name: r.get(6)?,
                server_id: sid.clone(),
                endpoints: advertised_urls(),
            })
        })
        .map_err(|_| AuthError::Internal)?
        .filter_map(Result::ok)
        .collect();
    Ok(Json(invites))
}

pub async fn revoke_invite(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = require_parent(&conn, &user.id.to_string())?;
    let changed = conn
        .execute(
            "UPDATE family_invites SET revoked_at = ?3
             WHERE id = ?1 AND family_id = ?2 AND used_at IS NULL AND revoked_at IS NULL",
            params![id, family_id, Utc::now().to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
    if changed == 0 {
        return Err(AuthError::NotFound("no pending invite with that id".into()));
    }
    Ok(Json(json!({ "revoked": true })))
}

#[derive(Debug, Deserialize)]
pub struct RedeemInviteRequest {
    pub invite_id: String,
    pub secret: String,
    /// Display name for a new passwordless account (ignored when a bearer token is sent).
    #[serde(default)]
    pub name: Option<String>,
    #[serde(flatten)]
    pub device: DeviceKeyRequest,
}

#[derive(Debug, Serialize)]
pub struct RedeemInviteResponse {
    pub token: String,
    pub user: User,
    pub device_id: String,
    pub family: Family,
    pub role: String,
    pub access_expires_at: Option<String>,
}

/// `POST /invites/redeem`: the joiner's single step. Without a bearer token this creates a
/// passwordless account; with one (an existing account that has no family) it reuses it.
pub async fn redeem_invite(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<RedeemInviteRequest>,
) -> Result<Json<RedeemInviteResponse>, AuthError> {
    let bearer = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::to_string);
    let existing_user = match bearer {
        Some(token) => Some(user_from_token(&state.db, &token)?),
        None => None,
    };

    let now = Utc::now();
    let mut conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let tx = conn.transaction().map_err(|_| AuthError::Internal)?;
    let invite: Option<(
        String,
        String,
        String,
        Option<i64>,
        String,
        Option<String>,
        Option<String>,
    )> = tx
        .query_row(
            "SELECT family_id, secret_hash, role, access_hours, expires_at, used_at, revoked_at
             FROM family_invites WHERE id = ?1",
            params![body.invite_id],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                    r.get(6)?,
                ))
            },
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;
    let invalid =
        || AuthError::NotFound("invite is invalid, used, or expired; ask for a new one".into());
    let (family_id, secret_hash, role, access_hours, expires_at, used_at, revoked_at) =
        invite.ok_or_else(invalid)?;
    if !digests_match(&secret_hash, &hash_secret(&body.secret))
        || used_at.is_some()
        || revoked_at.is_some()
        || parse_time(&expires_at).map_or(true, |e| e <= now)
    {
        return Err(invalid());
    }

    let user_id = match &existing_user {
        Some(u) => {
            if membership(&tx, &u.id.to_string())?.is_some() {
                return Err(AuthError::Conflict("already in a family".into()));
            }
            u.id
        }
        None => {
            let id = Uuid::new_v4();
            let name = clean_name(body.name.as_deref().unwrap_or(""), "Family member", 60);
            tx.execute(
                "INSERT INTO users (id, name, email, password_hash, created_at) VALUES (?1,?2,?3,?4,?5)",
                params![id.to_string(), name, synthetic_email(&id.to_string()), NO_PASSWORD_HASH, now.to_rfc3339()],
            )
            .map_err(|_| AuthError::Internal)?;
            id
        }
    };
    let uid = user_id.to_string();
    let device_name = clean_name(
        body.device.device_name.as_deref().unwrap_or(""),
        "iPhone",
        60,
    );
    let device_id = upsert_device(
        &tx,
        &uid,
        &body.device.public_key,
        &device_name,
        body.device.model.as_deref(),
    )?;
    let access_expires_at = access_hours.map(|h| (now + Duration::hours(h)).to_rfc3339());
    let consumed = tx
        .execute(
            "UPDATE family_invites SET used_at = ?2, used_by = ?3 WHERE id = ?1 AND used_at IS NULL",
            params![body.invite_id, now.to_rfc3339(), uid],
        )
        .map_err(|_| AuthError::Internal)?;
    if consumed != 1 {
        return Err(invalid());
    }
    tx.execute(
        "INSERT INTO family_members (family_id, user_id, role, joined_at, expires_at) VALUES (?1,?2,?3,?4,?5)",
        params![family_id, uid, role, now.to_rfc3339(), access_expires_at],
    )
    .map_err(|_| AuthError::Internal)?;
    let token = insert_session(&tx, user_id, Some(&device_id))?;
    let user = load_user(&tx, &uid)?;
    let family = load_family(&tx, &family_id)?;
    tx.commit().map_err(|_| AuthError::Internal)?;
    drop(conn);

    state.sync.publish_to_family(
        family.id,
        SyncEnvelope::new(
            "state",
            json!({ "action": "member_joined", "user_id": user.id, "role": role }),
        ),
    );
    Ok(Json(RedeemInviteResponse {
        token,
        user,
        device_id,
        family,
        role,
        access_expires_at,
    }))
}
