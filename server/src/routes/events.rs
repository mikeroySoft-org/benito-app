use axum::{
    extract::{Path, Query, State},
    Json,
};
use chrono::Utc;
use rusqlite::{params, OptionalExtension};
use serde::Deserialize;
use uuid::Uuid;

use crate::auth::{AuthError, AuthUser};
use crate::models::{CreateEventRequest, Event, UpdateEventRequest};
use crate::sync::{broadcast_event_delete, broadcast_event_upsert};
use crate::AppState;
use axum::http::HeaderMap;

#[derive(Debug, Deserialize)]
pub struct TimelineQuery {
    pub child_id: Option<Uuid>,
    pub limit: Option<i64>,
    /// RFC3339 cursor. When present, returns rows with `updated_at > since`
    /// (tombstones included) ordered `updated_at ASC, id ASC`.
    pub since: Option<String>,
}

const VALID_EVENT_TYPES: &[&str] = &[
    "feed_breast",
    "feed_bottle",
    "feed_solid",
    "diaper",
    "sleep",
    "pump",
    "medicine",
    "temperature",
    "growth",
    "milestone",
    "note",
    "custom",
    "activity",
];

/// Subtypes accepted for `type = "activity"`: a timed span logged like sleep — outings
/// (`walk`, `car_ride`) and mood (`crying`). A timer whose kind is one of these stops into
/// an `activity` event with that subtype.
pub(crate) const ACTIVITY_SUBTYPES: &[&str] = &["walk", "car_ride", "crying"];

/// `activity` events must name what kind of outing they were.
fn validate_activity_subtype(ty: &str, subtype: Option<&str>) -> Result<(), AuthError> {
    if ty != "activity" {
        return Ok(());
    }
    match subtype {
        Some(s) if ACTIVITY_SUBTYPES.contains(&s) => Ok(()),
        other => Err(AuthError::BadRequest(format!(
            "activity subtype must be one of {:?}, got {:?}",
            ACTIVITY_SUBTYPES, other
        ))),
    }
}

fn client_id_from(headers: &HeaderMap) -> Option<String> {
    headers
        .get("x-client-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

fn map_event(r: &rusqlite::Row<'_>) -> rusqlite::Result<Event> {
    let payload: Option<String> = r.get(10)?;
    Ok(Event {
        id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        child_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e))
        })?,
        r#type: r.get(2)?,
        subtype: r.get(3)?,
        started_at: parse_dt(&r.get::<_, String>(4)?)?,
        ended_at: r
            .get::<_, Option<String>>(5)?
            .map(|s| parse_dt(&s))
            .transpose()?,
        amount_value: r.get(6)?,
        amount_unit: r.get(7)?,
        side: r.get(8)?,
        notes: r.get(9)?,
        payload_json: payload.and_then(|s| serde_json::from_str(&s).ok()),
        created_by: Uuid::parse_str(&r.get::<_, String>(11)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(11, rusqlite::types::Type::Text, Box::new(e))
        })?,
        created_at: parse_dt(&r.get::<_, String>(12)?)?,
        updated_at: parse_dt(&r.get::<_, String>(13)?)?,
        deleted_at: r
            .get::<_, Option<String>>(14)?
            .map(|s| parse_dt(&s))
            .transpose()?,
    })
}

fn parse_dt(s: &str) -> rusqlite::Result<chrono::DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })
}

const EVENT_COLS: &str = "id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at";

fn user_can_access_child(
    conn: &rusqlite::Connection,
    user_id: Uuid,
    child_id: Uuid,
) -> Result<bool, AuthError> {
    let ok: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM children c
             JOIN family_members fm ON fm.family_id = c.family_id
             WHERE c.id = ?1 AND fm.user_id = ?2",
            params![child_id.to_string(), user_id.to_string()],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;
    Ok(ok.is_some())
}

fn parse_since(s: &str) -> Result<chrono::DateTime<Utc>, AuthError> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|_| AuthError::BadRequest("since must be RFC3339".into()))
}

pub async fn create_event(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    headers: HeaderMap,
    Json(body): Json<CreateEventRequest>,
) -> Result<Json<Event>, AuthError> {
    if !VALID_EVENT_TYPES.contains(&body.r#type.as_str()) {
        return Err(AuthError::BadRequest(format!(
            "invalid event type '{}'; expected one of {:?}",
            body.r#type, VALID_EVENT_TYPES
        )));
    }
    validate_activity_subtype(&body.r#type, body.subtype.as_deref())?;
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        if !user_can_access_child(&conn, user.id, body.child_id)? {
            return Err(AuthError::Unauthorized);
        }
        if let Some(existing) = existing_client_event(&conn, user.id, body.id)? {
            return Ok(Json(existing));
        }
    }
    let id = body.id.unwrap_or_else(Uuid::new_v4);
    let now = Utc::now();
    let started = body.started_at.unwrap_or(now);
    if started > now + chrono::Duration::minutes(EDIT_FUTURE_SLACK_MINUTES) {
        return Err(AuthError::BadRequest(
            "started_at cannot be in the future".into(),
        ));
    }
    if let Some(ended) = body.ended_at {
        if ended < started {
            return Err(AuthError::BadRequest(
                "ended_at cannot be before started_at".into(),
            ));
        }
    }
    let payload = body.payload_json.as_ref().map(|v| v.to_string());
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        conn.execute(
            "INSERT INTO events (id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,NULL)",
            params![
                id.to_string(),
                body.child_id.to_string(),
                body.r#type,
                body.subtype,
                started.to_rfc3339(),
                body.ended_at.map(|t| t.to_rfc3339()),
                body.amount_value,
                body.amount_unit,
                body.side,
                body.notes,
                payload,
                user.id.to_string(),
                now.to_rfc3339(),
                now.to_rfc3339(),
            ],
        )
        .map_err(|_| AuthError::Internal)?;
    }
    let event = Event {
        id,
        child_id: body.child_id,
        r#type: body.r#type,
        subtype: body.subtype,
        started_at: started,
        ended_at: body.ended_at,
        amount_value: body.amount_value,
        amount_unit: body.amount_unit,
        side: body.side,
        notes: body.notes,
        payload_json: body.payload_json,
        created_by: user.id,
        created_at: now,
        updated_at: now,
        deleted_at: None,
    };
    broadcast_event_upsert(&state.sync, &state.db, &event, client_id_from(&headers));
    Ok(Json(event))
}

/// The event already stored under a client-chosen id, if any. An id that belongs to a
/// family this user can't see is a conflict, never a leak of that event.
fn existing_client_event(
    conn: &rusqlite::Connection,
    user_id: Uuid,
    id: Option<Uuid>,
) -> Result<Option<Event>, AuthError> {
    let Some(id) = id else { return Ok(None) };
    let found = conn.query_row(
        &format!("SELECT {EVENT_COLS} FROM events WHERE id = ?1"),
        params![id.to_string()],
        map_event,
    );
    match found {
        Ok(event) => {
            if user_can_access_child(conn, user_id, event.child_id)? {
                Ok(Some(event))
            } else {
                Err(AuthError::Conflict("event id already in use".into()))
            }
        }
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(_) => Err(AuthError::Internal),
    }
}

pub async fn list_events(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Query(q): Query<TimelineQuery>,
) -> Result<Json<Vec<Event>>, AuthError> {
    timeline_inner(state, user, q).await
}

pub async fn timeline(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Query(q): Query<TimelineQuery>,
) -> Result<Json<Vec<Event>>, AuthError> {
    timeline_inner(state, user, q).await
}

async fn timeline_inner(
    state: AppState,
    user: crate::models::User,
    q: TimelineQuery,
) -> Result<Json<Vec<Event>>, AuthError> {
    let limit = q.limit.unwrap_or(100).clamp(1, 500);
    // Stored timestamps are `DateTime<Utc>::to_rfc3339()` text; bind the cursor in the
    // same format so SQLite's text comparison orders them correctly.
    let since = q
        .since
        .as_deref()
        .map(parse_since)
        .transpose()?
        .map(|t| t.to_rfc3339());
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let (scope, sql) = if let Some(child_id) = q.child_id {
        if !user_can_access_child(&conn, user.id, child_id)? {
            return Err(AuthError::Unauthorized);
        }
        let sql = if since.is_some() {
            format!(
                "SELECT {EVENT_COLS} FROM events WHERE child_id = ?1 AND updated_at > ?3 ORDER BY updated_at ASC, id ASC LIMIT ?2"
            )
        } else {
            format!(
                "SELECT {EVENT_COLS} FROM events WHERE child_id = ?1 AND deleted_at IS NULL ORDER BY started_at DESC LIMIT ?2"
            )
        };
        (child_id.to_string(), sql)
    } else {
        let sql = if since.is_some() {
            format!(
                "SELECT {EVENT_COLS} FROM events
                 WHERE child_id IN (
                     SELECT c.id FROM children c
                     JOIN family_members fm ON fm.family_id = c.family_id
                     WHERE fm.user_id = ?1
                 ) AND updated_at > ?3
                 ORDER BY updated_at ASC, id ASC LIMIT ?2"
            )
        } else {
            "SELECT e.id, e.child_id, e.type, e.subtype, e.started_at, e.ended_at, e.amount_value, e.amount_unit, e.side, e.notes, e.payload_json, e.created_by, e.created_at, e.updated_at, e.deleted_at
                 FROM events e
                 JOIN children c ON c.id = e.child_id
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1 AND e.deleted_at IS NULL
                 ORDER BY e.started_at DESC LIMIT ?2"
                .to_string()
        };
        (user.id.to_string(), sql)
    };
    let mut stmt = conn.prepare(&sql).map_err(|_| AuthError::Internal)?;
    let rows = match &since {
        Some(since) => stmt.query_map(params![scope, limit, since], map_event),
        None => stmt.query_map(params![scope, limit], map_event),
    }
    .map_err(|_| AuthError::Internal)?;
    let events = rows
        .collect::<rusqlite::Result<Vec<Event>>>()
        .map_err(|_| AuthError::Internal)?;
    Ok(Json(events))
}

pub async fn update_event(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Json(body): Json<UpdateEventRequest>,
) -> Result<Json<Event>, AuthError> {
    let now = Utc::now();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let (child_id, current_started, current_ended, current_type): (String, String, Option<String>, String) = conn
        .query_row(
            "SELECT child_id, started_at, ended_at, type FROM events WHERE id = ?1 AND deleted_at IS NULL",
            params![id.to_string()],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .map_err(|_| AuthError::NotFound("event not found".into()))?;
    let child_uuid = Uuid::parse_str(&child_id).map_err(|_| AuthError::Internal)?;
    if !user_can_access_child(&conn, user.id, child_uuid)? {
        return Err(AuthError::Unauthorized);
    }
    validate_edit_times(&body, &current_started, current_ended.as_deref(), now)?;
    if body.subtype.is_some() {
        validate_activity_subtype(&current_type, body.subtype.as_deref())?;
    }
    conn.execute(
        "UPDATE events SET
            subtype = COALESCE(?2, subtype),
            started_at = COALESCE(?3, started_at),
            ended_at = COALESCE(?4, ended_at),
            amount_value = COALESCE(?5, amount_value),
            amount_unit = COALESCE(?6, amount_unit),
            side = COALESCE(?7, side),
            notes = COALESCE(?8, notes),
            payload_json = COALESCE(?9, payload_json),
            updated_at = ?10
         WHERE id = ?1",
        params![
            id.to_string(),
            body.subtype,
            body.started_at.map(|t| t.to_rfc3339()),
            body.ended_at.map(|t| t.to_rfc3339()),
            body.amount_value,
            body.amount_unit,
            body.side,
            body.notes,
            body.payload_json.as_ref().map(|v| v.to_string()),
            now.to_rfc3339(),
        ],
    )
    .map_err(|_| AuthError::Internal)?;
    let event = conn
        .query_row(
            &format!("SELECT {EVENT_COLS} FROM events WHERE id = ?1"),
            params![id.to_string()],
            map_event,
        )
        .map_err(|_| AuthError::Internal)?;
    drop(conn);
    broadcast_event_upsert(&state.sync, &state.db, &event, client_id_from(&headers));
    Ok(Json(event))
}

/// How far into the future an edited `started_at` may land (client clock skew).
const EDIT_FUTURE_SLACK_MINUTES: i64 = 5;

/// Rejects an edit whose resulting span would be inverted or whose new start is in the future.
/// Only times the request touches are checked, so editing notes on an old row never fails.
fn validate_edit_times(
    body: &UpdateEventRequest,
    current_started: &str,
    current_ended: Option<&str>,
    now: chrono::DateTime<Utc>,
) -> Result<(), AuthError> {
    if body.started_at.is_none() && body.ended_at.is_none() {
        return Ok(());
    }
    if let Some(started) = body.started_at {
        if started > now + chrono::Duration::minutes(EDIT_FUTURE_SLACK_MINUTES) {
            return Err(AuthError::BadRequest(
                "started_at cannot be in the future".into(),
            ));
        }
    }
    let started = match body.started_at {
        Some(t) => t,
        None => parse_dt(current_started).map_err(|_| AuthError::Internal)?,
    };
    let ended = match body.ended_at {
        Some(t) => Some(t),
        None => current_ended
            .map(parse_dt)
            .transpose()
            .map_err(|_| AuthError::Internal)?,
    };
    if let Some(ended) = ended {
        if ended < started {
            return Err(AuthError::BadRequest(
                "ended_at cannot be before started_at".into(),
            ));
        }
    }
    Ok(())
}

pub async fn delete_event(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
) -> Result<Json<serde_json::Value>, AuthError> {
    let now = Utc::now();
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let child_id: String = conn
        .query_row(
            "SELECT child_id FROM events WHERE id = ?1 AND deleted_at IS NULL",
            params![id.to_string()],
            |r| r.get(0),
        )
        .map_err(|_| AuthError::NotFound("event not found".into()))?;
    let child_uuid = Uuid::parse_str(&child_id).map_err(|_| AuthError::Internal)?;
    if !user_can_access_child(&conn, user.id, child_uuid)? {
        return Err(AuthError::Unauthorized);
    }
    conn.execute(
        "UPDATE events SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1",
        params![id.to_string(), now.to_rfc3339()],
    )
    .map_err(|_| AuthError::Internal)?;
    drop(conn);
    broadcast_event_delete(
        &state.sync,
        &state.db,
        id,
        child_uuid,
        client_id_from(&headers),
    );
    Ok(Json(serde_json::json!({ "ok": true, "id": id })))
}
