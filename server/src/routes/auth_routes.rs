use axum::{extract::State, Json};
use chrono::{Duration, Utc};
use rusqlite::params;
use uuid::Uuid;

use crate::auth::{
    create_session, hash_password, invite_code, new_session_token, verify_password, AuthError,
    AuthUser,
};
use crate::models::{
    AuthResponse, Child, CreateChildRequest, CreateFamilyRequest, CreateFamilyResponse,
    CreatePairingTokenResponse, Family, JoinFamilyRequest, LoginRequest, MeResponse,
    PairWithTokenRequest, RegisterRequest, User,
};
use crate::sync::SyncEnvelope;
use crate::AppState;
use serde_json::json;

pub async fn register(
    State(state): State<AppState>,
    Json(body): Json<RegisterRequest>,
) -> Result<Json<AuthResponse>, AuthError> {
    if body.email.trim().is_empty() || body.password.len() < 8 {
        return Err(AuthError::BadRequest(
            "email required; password min 8 chars".into(),
        ));
    }
    let id = Uuid::new_v4();
    let now = Utc::now();
    let password_hash = hash_password(&body.password)?;
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        conn.execute(
            "INSERT INTO users (id, name, email, password_hash, created_at) VALUES (?1,?2,?3,?4,?5)",
            params![
                id.to_string(),
                body.name.trim(),
                body.email.trim().to_lowercase(),
                password_hash,
                now.to_rfc3339()
            ],
        )
        .map_err(|e| {
            if let rusqlite::Error::SqliteFailure(err, _) = &e {
                if err.code == rusqlite::ErrorCode::ConstraintViolation {
                    return AuthError::Conflict("email already registered".into());
                }
            }
            AuthError::Internal
        })?;
    }
    let user = User {
        id,
        name: body.name.trim().to_string(),
        email: body.email.trim().to_lowercase(),
        created_at: now,
    };
    let token = create_session(&state.db, id)?;
    Ok(Json(AuthResponse { token, user }))
}

pub async fn login(
    State(state): State<AppState>,
    Json(body): Json<LoginRequest>,
) -> Result<Json<AuthResponse>, AuthError> {
    let email = body.email.trim().to_lowercase();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let row = conn
        .query_row(
            "SELECT id, name, email, password_hash, created_at FROM users WHERE email = ?1",
            params![email],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, String>(4)?,
                ))
            },
        )
        .map_err(|_| AuthError::Unauthorized)?;
    drop(conn);

    if !verify_password(&body.password, &row.3)? {
        return Err(AuthError::Unauthorized);
    }
    let id = Uuid::parse_str(&row.0).map_err(|_| AuthError::Internal)?;
    let user = User {
        id,
        name: row.1,
        email: row.2,
        created_at: chrono::DateTime::parse_from_rfc3339(&row.4)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| AuthError::Internal)?,
    };
    let token = create_session(&state.db, id)?;
    Ok(Json(AuthResponse { token, user }))
}

pub async fn create_family(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Json(body): Json<CreateFamilyRequest>,
) -> Result<Json<CreateFamilyResponse>, AuthError> {
    // One family membership per user for v1a (keep simple).
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let existing: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM family_members WHERE user_id = ?1 LIMIT 1",
                params![user.id.to_string()],
                |r| r.get(0),
            )
            .optional_row()
            .map_err(|_| AuthError::Internal)?;
        if existing.is_some() {
            return Err(AuthError::Conflict("already in a family".into()));
        }
    }

    let family_id = Uuid::new_v4();
    let child_id = Uuid::new_v4();
    let now = Utc::now();
    let code = invite_code();
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        conn.execute(
            "INSERT INTO families (id, name, invite_code, created_at) VALUES (?1,?2,?3,?4)",
            params![
                family_id.to_string(),
                body.name.trim(),
                code,
                now.to_rfc3339()
            ],
        )
        .map_err(|_| AuthError::Internal)?;
        conn.execute(
            "INSERT INTO family_members (family_id, user_id, role, joined_at) VALUES (?1,?2,'parent',?3)",
            params![family_id.to_string(), user.id.to_string(), now.to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
        conn.execute(
            "INSERT INTO children (id, family_id, name, birthdate, sex, created_at) VALUES (?1,?2,?3,?4,?5,?6)",
            params![
                child_id.to_string(),
                family_id.to_string(),
                body.child_name.trim(),
                body.child_birthdate,
                body.child_sex,
                now.to_rfc3339()
            ],
        )
        .map_err(|_| AuthError::Internal)?;
    }
    let family = Family {
        id: family_id,
        name: body.name.trim().to_string(),
        invite_code: code.clone(),
        created_at: now,
    };
    let child = Child {
        id: child_id,
        family_id,
        name: body.child_name.trim().to_string(),
        birthdate: body.child_birthdate,
        sex: body.child_sex,
        created_at: now,
    };
    Ok(Json(CreateFamilyResponse {
        family,
        child,
        invite_code: code,
    }))
}

pub async fn join_family(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Json(body): Json<JoinFamilyRequest>,
) -> Result<Json<Family>, AuthError> {
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let existing: Option<i64> = conn
            .query_row(
                "SELECT 1 FROM family_members WHERE user_id = ?1 LIMIT 1",
                params![user.id.to_string()],
                |r| r.get(0),
            )
            .optional_row()
            .map_err(|_| AuthError::Internal)?;
        if existing.is_some() {
            return Err(AuthError::Conflict("already in a family".into()));
        }
    }

    let code = body.invite_code.trim().to_uppercase();
    let now = Utc::now();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let (id, name, invite_code, created_at): (String, String, String, String) = conn
        .query_row(
            "SELECT id, name, invite_code, created_at FROM families WHERE invite_code = ?1",
            params![code],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|_| AuthError::NotFound("invalid invite code".into()))?;
    conn.execute(
        "INSERT OR IGNORE INTO family_members (family_id, user_id, role, joined_at) VALUES (?1,?2,'parent',?3)",
        params![id, user.id.to_string(), now.to_rfc3339()],
    )
    .map_err(|_| AuthError::Internal)?;
    drop(conn);
    let family = Family {
        id: Uuid::parse_str(&id).map_err(|_| AuthError::Internal)?,
        name,
        invite_code,
        created_at: chrono::DateTime::parse_from_rfc3339(&created_at)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| AuthError::Internal)?,
    };
    state.sync.publish_to_family(
        family.id,
        SyncEnvelope::new(
            "state",
            json!({ "action": "member_joined", "user_id": user.id }),
        ),
    );
    Ok(Json(family))
}

pub async fn me(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<MeResponse>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family = conn
        .query_row(
            "SELECT f.id, f.name, f.invite_code, f.created_at
             FROM families f
             JOIN family_members fm ON fm.family_id = f.id
             WHERE fm.user_id = ?1
             LIMIT 1",
            params![user.id.to_string()],
            |r| {
                Ok(Family {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    name: r.get(1)?,
                    invite_code: r.get(2)?,
                    created_at: chrono::DateTime::parse_from_rfc3339(&r.get::<_, String>(3)?)
                        .map(|d| d.with_timezone(&Utc))
                        .map_err(|e| {
                            rusqlite::Error::FromSqlConversionFailure(
                                3,
                                rusqlite::types::Type::Text,
                                Box::new(e),
                            )
                        })?,
                })
            },
        )
        .optional_row()
        .map_err(|_| AuthError::Internal)?;

    let mut children = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT c.id, c.family_id, c.name, c.birthdate, c.sex, c.created_at
                 FROM children c
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1
                 ORDER BY c.created_at ASC",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], map_child)
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            children.push(row.map_err(|_| AuthError::Internal)?);
        }
    }

    let (role, access_expires_at): (Option<String>, Option<String>) = conn
        .query_row(
            "SELECT role, expires_at FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user.id.to_string()],
            |r| Ok((Some(r.get(0)?), r.get(1)?)),
        )
        .unwrap_or((None, None));
    let has_device_key: bool = conn
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM devices WHERE user_id = ?1 AND revoked_at IS NULL)",
            params![user.id.to_string()],
            |r| r.get(0),
        )
        .unwrap_or(false);

    Ok(Json(MeResponse {
        user,
        family,
        children,
        role,
        access_expires_at,
        has_device_key,
    }))
}

pub async fn rotate_invite(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<Family>, AuthError> {
    let now = Utc::now();
    let new_code = invite_code();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    crate::routes::sharing::require_parent(&conn, &user.id.to_string())?;
    let (id, name, _old_code, created_at): (String, String, String, String) = conn
        .query_row(
            "SELECT f.id, f.name, f.invite_code, f.created_at
             FROM families f
             JOIN family_members fm ON fm.family_id = f.id
             WHERE fm.user_id = ?1
             LIMIT 1",
            params![user.id.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|_| AuthError::BadRequest("join or create a family first".into()))?;

    // Unique retry once on collision (alphabet is large; still belt-and-suspenders).
    let mut code = new_code;
    for _ in 0..5 {
        match conn.execute(
            "UPDATE families SET invite_code = ?1 WHERE id = ?2",
            params![code, id],
        ) {
            Ok(_) => break,
            Err(e) => {
                if let rusqlite::Error::SqliteFailure(err, _) = &e {
                    if err.code == rusqlite::ErrorCode::ConstraintViolation {
                        code = invite_code();
                        continue;
                    }
                }
                return Err(AuthError::Internal);
            }
        }
    }
    drop(conn);

    let family_id = Uuid::parse_str(&id).map_err(|_| AuthError::Internal)?;
    let family = Family {
        id: family_id,
        name,
        invite_code: code.clone(),
        created_at: chrono::DateTime::parse_from_rfc3339(&created_at)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| AuthError::Internal)?,
    };
    state.sync.publish_to_family(
        family_id,
        SyncEnvelope::new(
            "state",
            json!({ "action": "invite_rotated", "invite_code": code, "at": now.to_rfc3339() }),
        ),
    );
    Ok(Json(family))
}

/// Pairing tokens are handed over a live proximity session, so they only need to outlive it briefly.
const PAIRING_TOKEN_TTL_MINUTES: i64 = 5;

pub async fn create_pairing_token(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<CreatePairingTokenResponse>, AuthError> {
    let now = Utc::now();
    let expires_at = now + Duration::minutes(PAIRING_TOKEN_TTL_MINUTES);
    let token = new_session_token();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    crate::routes::sharing::require_parent(&conn, &user.id.to_string())?;
    let (family_id, family_name): (String, String) = conn
        .query_row(
            "SELECT f.id, f.name
             FROM families f
             JOIN family_members fm ON fm.family_id = f.id
             WHERE fm.user_id = ?1
             LIMIT 1",
            params![user.id.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|_| AuthError::NotFound("no family".into()))?;
    conn.execute(
        "INSERT INTO pairing_tokens (token, family_id, created_by, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            token,
            family_id,
            user.id.to_string(),
            now.to_rfc3339(),
            expires_at.to_rfc3339()
        ],
    )
    .map_err(|_| AuthError::Internal)?;
    Ok(Json(CreatePairingTokenResponse {
        token,
        family_name,
        expires_at,
    }))
}

pub async fn pair_with_token(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Json(body): Json<PairWithTokenRequest>,
) -> Result<Json<Family>, AuthError> {
    let now = Utc::now().to_rfc3339();
    let user_id = user.id.to_string();
    // One lock + one transaction: the membership check, the single-use consumption, and the
    // membership insert all happen together, so two redemptions of one token can't both win and
    // a failed insert doesn't burn the token.
    let mut conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let tx = conn.transaction().map_err(|_| AuthError::Internal)?;
    let existing: Option<i64> = tx
        .query_row(
            "SELECT 1 FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user_id],
            |r| r.get(0),
        )
        .optional_row()
        .map_err(|_| AuthError::Internal)?;
    if existing.is_some() {
        return Err(AuthError::Conflict("already in a family".into()));
    }
    let consumed = tx
        .execute(
            "UPDATE pairing_tokens SET used_at = ?1, used_by = ?2
             WHERE token = ?3 AND used_at IS NULL AND expires_at > ?1",
            params![now, user_id, body.token],
        )
        .map_err(|_| AuthError::Internal)?;
    if consumed != 1 {
        return Err(AuthError::NotFound(
            "invalid or expired pairing token".into(),
        ));
    }
    let (id, name, invite_code, created_at): (String, String, String, String) = tx
        .query_row(
            "SELECT f.id, f.name, f.invite_code, f.created_at
             FROM pairing_tokens p
             JOIN families f ON f.id = p.family_id
             WHERE p.token = ?1",
            params![body.token],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|_| AuthError::Internal)?;
    tx.execute(
        "INSERT INTO family_members (family_id, user_id, role, joined_at) VALUES (?1,?2,'parent',?3)",
        params![id, user_id, now],
    )
    .map_err(|_| AuthError::Internal)?;
    tx.commit().map_err(|_| AuthError::Internal)?;
    drop(conn);
    let family = Family {
        id: Uuid::parse_str(&id).map_err(|_| AuthError::Internal)?,
        name,
        invite_code,
        created_at: chrono::DateTime::parse_from_rfc3339(&created_at)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|_| AuthError::Internal)?,
    };
    state.sync.publish_to_family(
        family.id,
        SyncEnvelope::new(
            "state",
            json!({ "action": "member_joined", "user_id": user.id }),
        ),
    );
    Ok(Json(family))
}

/// Removes the caller from their family (troubleshooting / switching families). The family and
/// its data stay for the remaining members; the caller can then create or join another.
pub async fn leave_family(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id: String = conn
        .query_row(
            "SELECT family_id FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user.id.to_string()],
            |r| r.get(0),
        )
        .map_err(|_| AuthError::NotFound("no family".into()))?;
    conn.execute(
        "DELETE FROM family_members WHERE family_id = ?1 AND user_id = ?2",
        params![family_id, user.id.to_string()],
    )
    .map_err(|_| AuthError::Internal)?;
    drop(conn);
    let family_id = Uuid::parse_str(&family_id).map_err(|_| AuthError::Internal)?;
    state.sync.publish_to_family(
        family_id,
        SyncEnvelope::new(
            "state",
            json!({ "action": "member_left", "user_id": user.id }),
        ),
    );
    Ok(Json(json!({ "left": true })))
}

pub async fn list_children(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<Vec<Child>>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let mut children = Vec::new();
    let mut stmt = conn
        .prepare(
            "SELECT c.id, c.family_id, c.name, c.birthdate, c.sex, c.created_at
             FROM children c
             JOIN family_members fm ON fm.family_id = c.family_id
             WHERE fm.user_id = ?1
             ORDER BY c.created_at ASC",
        )
        .map_err(|_| AuthError::Internal)?;
    let rows = stmt
        .query_map(params![user.id.to_string()], map_child)
        .map_err(|_| AuthError::Internal)?;
    for row in rows {
        children.push(row.map_err(|_| AuthError::Internal)?);
    }
    Ok(Json(children))
}

pub async fn create_child(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Json(body): Json<CreateChildRequest>,
) -> Result<Json<Child>, AuthError> {
    if body.name.trim().is_empty() {
        return Err(AuthError::BadRequest("name required".into()));
    }
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id: String = conn
        .query_row(
            "SELECT family_id FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user.id.to_string()],
            |r| r.get(0),
        )
        .map_err(|_| AuthError::BadRequest("join or create a family first".into()))?;
    let child_id = Uuid::new_v4();
    let now = Utc::now();
    let family_uuid = Uuid::parse_str(&family_id).map_err(|_| AuthError::Internal)?;
    conn.execute(
        "INSERT INTO children (id, family_id, name, birthdate, sex, created_at) VALUES (?1,?2,?3,?4,?5,?6)",
        params![
            child_id.to_string(),
            family_id,
            body.name.trim(),
            body.birthdate,
            body.sex,
            now.to_rfc3339()
        ],
    )
    .map_err(|_| AuthError::Internal)?;
    drop(conn);

    let child = Child {
        id: child_id,
        family_id: family_uuid,
        name: body.name.trim().to_string(),
        birthdate: body.birthdate,
        sex: body.sex,
        created_at: now,
    };
    state.sync.publish_to_family(
        family_uuid,
        SyncEnvelope::new(
            "state",
            json!({ "action": "child_added", "child_id": child_id }),
        ),
    );
    Ok(Json(child))
}

fn map_child(r: &rusqlite::Row<'_>) -> rusqlite::Result<Child> {
    Ok(Child {
        id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        family_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e))
        })?,
        name: r.get(2)?,
        birthdate: r.get(3)?,
        sex: r.get(4)?,
        created_at: chrono::DateTime::parse_from_rfc3339(&r.get::<_, String>(5)?)
            .map(|d| d.with_timezone(&Utc))
            .map_err(|e| {
                rusqlite::Error::FromSqlConversionFailure(
                    5,
                    rusqlite::types::Type::Text,
                    Box::new(e),
                )
            })?,
    })
}

trait OptionalRow<T> {
    fn optional_row(self) -> rusqlite::Result<Option<T>>;
}

impl<T> OptionalRow<T> for rusqlite::Result<T> {
    fn optional_row(self) -> rusqlite::Result<Option<T>> {
        match self {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}
