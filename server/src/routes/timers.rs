use axum::{
    body::Bytes,
    extract::{Path, Query, State},
    http::HeaderMap,
    Json,
};
use chrono::Utc;
use rusqlite::{params, OptionalExtension};
use serde::Deserialize;
use uuid::Uuid;

use crate::auth::{AuthError, AuthUser};
use crate::models::{AdjustTimerRequest, Event, StartTimerRequest, Timer, TimerAtRequest};
use crate::sync::{
    broadcast_event_upsert, broadcast_timer_stop, broadcast_timer_upsert, family_id_for_child,
};
use crate::routes::events::ACTIVITY_SUBTYPES;
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct TimerQuery {
    pub child_id: Option<Uuid>,
}

fn client_id_from(headers: &HeaderMap) -> Option<String> {
    headers
        .get("x-client-id")
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string())
}

fn normalize_side(side: Option<&str>) -> Option<String> {
    side.map(|s| s.trim().to_uppercase())
        .filter(|s| s == "L" || s == "R" || s == "BOTH")
}

fn parse_ts(s: &str, idx: usize) -> rusqlite::Result<chrono::DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(idx, rusqlite::types::Type::Text, Box::new(e))
        })
}

fn map_timer(r: &rusqlite::Row<'_>) -> rusqlite::Result<Timer> {
    Ok(Timer {
        id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        child_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e))
        })?,
        kind: r.get(2)?,
        started_at: parse_ts(&r.get::<_, String>(3)?, 3)?,
        started_by: Uuid::parse_str(&r.get::<_, String>(4)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, Box::new(e))
        })?,
        state: r.get(5)?,
        stopped_at: r
            .get::<_, Option<String>>(6)?
            .map(|s| parse_ts(&s, 6))
            .transpose()?,
        updated_at: parse_ts(&r.get::<_, String>(7)?, 7)?,
        side: r.get(8)?,
        paused_at: r
            .get::<_, Option<String>>(9)?
            .map(|s| parse_ts(&s, 9))
            .transpose()?,
        paused_seconds: r.get(10)?,
    })
}

const TIMER_SELECT: &str =
    "SELECT id, child_id, kind, started_at, started_by, state, stopped_at, updated_at, side, paused_at, paused_seconds FROM timers";

fn can_access(conn: &rusqlite::Connection, user_id: Uuid, child_id: Uuid) -> Result<bool, AuthError> {
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

fn load_timer(conn: &rusqlite::Connection, id: Uuid) -> Result<Timer, AuthError> {
    conn.query_row(
        &format!("{TIMER_SELECT} WHERE id = ?1"),
        params![id.to_string()],
        map_timer,
    )
    .map_err(|_| AuthError::Internal)
}

/// Loads a timer the caller may act on: 404 if unknown, 401 if outside the caller's family.
fn load_accessible_timer(
    conn: &rusqlite::Connection,
    user_id: Uuid,
    id: Uuid,
) -> Result<Timer, AuthError> {
    let timer = conn
        .query_row(
            &format!("{TIMER_SELECT} WHERE id = ?1"),
            params![id.to_string()],
            map_timer,
        )
        .optional()
        .map_err(|_| AuthError::Internal)?
        .ok_or_else(|| AuthError::NotFound("timer not found".into()))?;
    if !can_access(conn, user_id, timer.child_id)? {
        return Err(AuthError::Unauthorized);
    }
    Ok(timer)
}


/// How far a client `at` may sit ahead of server `Utc::now()` (phone clock skew).
const CLIENT_AT_FUTURE_SLACK_SECS: i64 = 300;
/// How far back a client `at` may sit (covers offline queue delay).
const CLIENT_AT_MAX_AGE_HOURS: i64 = 24;

/// Prefer the phone's wall clock when provided; fall back to server `Utc::now()`.
/// Timer `started_at` / `paused_at` / `stopped_at` are stored as these values so device
/// `Date()` elapsed displays are honest without a client-side skew correction.
fn action_time(at: Option<chrono::DateTime<Utc>>) -> Result<chrono::DateTime<Utc>, AuthError> {
    let server = Utc::now();
    let Some(client) = at else {
        return Ok(server);
    };
    if client > server + chrono::Duration::seconds(CLIENT_AT_FUTURE_SLACK_SECS) {
        return Err(AuthError::BadRequest(
            "at cannot be more than 5 minutes in the future".into(),
        ));
    }
    if client < server - chrono::Duration::hours(CLIENT_AT_MAX_AGE_HOURS) {
        return Err(AuthError::BadRequest(
            "at cannot be more than 24 hours ago".into(),
        ));
    }
    Ok(client)
}

/// `{"at"?}` body for pause / resume / stop. The body itself is optional: an empty body
/// (with or without a JSON content type) means "use server time".
fn timer_action_at(body: &Bytes) -> Result<Option<chrono::DateTime<Utc>>, AuthError> {
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(None);
    }
    serde_json::from_slice::<TimerAtRequest>(body)
        .map(|req| req.at)
        .map_err(|e| AuthError::BadRequest(format!("invalid JSON body: {e}")))
}

/// Seconds of the pause in progress at `now` (0 unless the timer is paused).
fn open_pause_seconds(timer: &Timer, now: chrono::DateTime<Utc>) -> i64 {
    match (timer.state.as_str(), timer.paused_at) {
        ("paused", Some(paused_at)) => (now - paused_at).num_seconds().max(0),
        _ => 0,
    }
}

pub async fn start_timer(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    headers: HeaderMap,
    Json(body): Json<StartTimerRequest>,
) -> Result<Json<Timer>, AuthError> {
    let kind = body.kind.trim().to_lowercase();
    if kind.is_empty() {
        return Err(AuthError::BadRequest(
            "kind required (e.g. sleep, feed_breast)".into(),
        ));
    }
    let side = normalize_side(body.side.as_deref());
    if kind == "feed_breast" && side.is_none() {
        return Err(AuthError::BadRequest(
            "feed_breast timer requires side L or R".into(),
        ));
    }
    let id = Uuid::new_v4();
    let now = action_time(body.at)?;
    let updated_at = Utc::now();
    {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        if !can_access(&conn, user.id, body.child_id)? {
            return Err(AuthError::Unauthorized);
        }
        conn.execute(
            "INSERT INTO timers (id, child_id, kind, started_at, started_by, state, stopped_at, updated_at, side, paused_at, paused_seconds)
             VALUES (?1,?2,?3,?4,?5,'running',NULL,?6,?7,NULL,0)",
            params![
                id.to_string(),
                body.child_id.to_string(),
                kind,
                now.to_rfc3339(),
                user.id.to_string(),
                updated_at.to_rfc3339(),
                side,
            ],
        )
        .map_err(|_| AuthError::Internal)?;
    }
    let timer = Timer {
        id,
        child_id: body.child_id,
        kind,
        started_at: now,
        started_by: user.id,
        state: "running".into(),
        stopped_at: None,
        updated_at,
        side,
        paused_at: None,
        paused_seconds: 0,
    };
    broadcast_timer_upsert(&state.sync, &state.db, &timer, client_id_from(&headers));
    Ok(Json(timer))
}

pub async fn pause_timer(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Timer>, AuthError> {
    let now = action_time(timer_action_at(&body)?)?;
    let updated_at = Utc::now();
    let timer = {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let current = load_accessible_timer(&conn, user.id, id)?;
        if current.state != "running" {
            return Err(AuthError::Conflict("timer is not running".into()));
        }
        if now < current.started_at {
            return Err(AuthError::BadRequest(
                "at cannot be before the timer started".into(),
            ));
        }
        conn.execute(
            "UPDATE timers SET state = 'paused', paused_at = ?2, updated_at = ?3 WHERE id = ?1",
            params![id.to_string(), now.to_rfc3339(), updated_at.to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
        load_timer(&conn, id)?
    };
    broadcast_timer_upsert(&state.sync, &state.db, &timer, client_id_from(&headers));
    Ok(Json(timer))
}

pub async fn resume_timer(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Timer>, AuthError> {
    let now = action_time(timer_action_at(&body)?)?;
    let updated_at = Utc::now();
    let timer = {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let current = load_accessible_timer(&conn, user.id, id)?;
        if current.state != "paused" {
            return Err(AuthError::Conflict("timer is not paused".into()));
        }
        if let Some(paused_at) = current.paused_at {
            if now < paused_at {
                return Err(AuthError::BadRequest(
                    "at cannot be before the timer was paused".into(),
                ));
            }
        }
        conn.execute(
            "UPDATE timers SET state = 'running', paused_seconds = paused_seconds + ?2, paused_at = NULL, updated_at = ?3
             WHERE id = ?1",
            params![
                id.to_string(),
                open_pause_seconds(&current, now),
                updated_at.to_rfc3339(),
            ],
        )
        .map_err(|_| AuthError::Internal)?;
        load_timer(&conn, id)?
    };
    broadcast_timer_upsert(&state.sync, &state.db, &timer, client_id_from(&headers));
    Ok(Json(timer))
}

/// How far into the future a corrected start may land (client clock skew).
const ADJUST_FUTURE_SLACK_SECS: i64 = 60;
/// How far back a running timer's start may be moved.
const ADJUST_MAX_AGE_HOURS: i64 = 24;

/// `PATCH /timers/{id}`: move an active timer's `started_at` (e.g. "forgot to start it
/// 10 minutes ago"). The auto-created event on stop inherits the corrected start.
pub async fn adjust_timer(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    Json(body): Json<AdjustTimerRequest>,
) -> Result<Json<Timer>, AuthError> {
    // Bounds follow the phone clock when `at` is set so a fast phone can move
    // the start to "now" without the server clock rejecting it. `updated_at`
    // below stays server time.
    let now = action_time(body.at)?;
    let started_at = body.started_at;
    let timer = {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let current = load_accessible_timer(&conn, user.id, id)?;
        if current.state != "running" && current.state != "paused" {
            return Err(AuthError::Conflict("timer is not active".into()));
        }
        if started_at > now + chrono::Duration::seconds(ADJUST_FUTURE_SLACK_SECS) {
            return Err(AuthError::BadRequest("started_at cannot be in the future".into()));
        }
        if started_at < now - chrono::Duration::hours(ADJUST_MAX_AGE_HOURS) {
            return Err(AuthError::BadRequest(
                "started_at cannot be more than 24 hours ago".into(),
            ));
        }
        if let ("paused", Some(paused_at)) = (current.state.as_str(), current.paused_at) {
            if started_at > paused_at {
                return Err(AuthError::BadRequest(
                    "started_at cannot be after the timer was paused".into(),
                ));
            }
        }
        let updated_at = Utc::now();
        conn.execute(
            "UPDATE timers SET started_at = ?2, updated_at = ?3 WHERE id = ?1",
            params![id.to_string(), started_at.to_rfc3339(), updated_at.to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
        load_timer(&conn, id)?
    };
    broadcast_timer_upsert(&state.sync, &state.db, &timer, client_id_from(&headers));
    Ok(Json(timer))
}

pub async fn stop_timer(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Path(id): Path<Uuid>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<Timer>, AuthError> {
    let now = action_time(timer_action_at(&body)?)?;
    let updated_at = Utc::now();
    // Keep the SQLite lock inside this block so it cannot span the APNs await below.
    let (timer, auto_event) = {
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let current = load_accessible_timer(&conn, user.id, id)?;
        if current.state == "stopped" {
            return Ok(Json(current));
        }
        if now < current.started_at {
            return Err(AuthError::BadRequest(
                "at cannot be before the timer started".into(),
            ));
        }

        // A paused timer folds its open pause into paused_seconds as it stops.
        conn.execute(
            "UPDATE timers SET state = 'stopped', stopped_at = ?2, updated_at = ?3,
                 paused_seconds = paused_seconds + ?4, paused_at = NULL
             WHERE id = ?1",
            params![
                id.to_string(),
                now.to_rfc3339(),
                updated_at.to_rfc3339(),
                open_pause_seconds(&current, now),
            ],
        )
        .map_err(|_| AuthError::Internal)?;
        let timer = load_timer(&conn, id)?;

        // Auto-created events keep the wall-clock span; paused time rides in payload_json so
        // durations can exclude it.
        let payload = (timer.paused_seconds > 0)
            .then(|| serde_json::json!({ "paused_seconds": timer.paused_seconds }));
        let payload_text = payload.as_ref().map(|v| v.to_string());

        // Auto-create the logged event when a timed activity stops (v1a convenience):
        // sleep, feed_breast (with side), and walk / car_ride / crying (`activity` + subtype).
        let auto_kind: Option<(&str, Option<&str>)> = match timer.kind.as_str() {
            "sleep" => Some(("sleep", None)),
            "feed_breast" => Some(("feed_breast", None)),
            kind if ACTIVITY_SUBTYPES.contains(&kind) => Some(("activity", Some(kind))),
            _ => None,
        };
        let auto_event = match auto_kind {
            Some((event_type, subtype)) => {
                let side = (event_type == "feed_breast").then(|| timer.side.clone()).flatten();
                let event_id = Uuid::new_v4();
                conn.execute(
                    "INSERT INTO events (id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at)
                     VALUES (?1,?2,?3,?4,?5,?6,NULL,NULL,?7,NULL,?8,?9,?10,?10,NULL)",
                    params![
                        event_id.to_string(),
                        timer.child_id.to_string(),
                        event_type,
                        subtype,
                        timer.started_at.to_rfc3339(),
                        now.to_rfc3339(),
                        side,
                        payload_text,
                        user.id.to_string(),
                        updated_at.to_rfc3339(),
                    ],
                )
                .map_err(|_| AuthError::Internal)?;
                Some(Event {
                    id: event_id,
                    child_id: timer.child_id,
                    r#type: event_type.into(),
                    subtype: subtype.map(Into::into),
                    started_at: timer.started_at,
                    ended_at: Some(now),
                    amount_value: None,
                    amount_unit: None,
                    side,
                    notes: None,
                    payload_json: payload,
                    created_by: user.id,
                    created_at: updated_at,
                    updated_at,
                    deleted_at: None,
                })
            }
            None => None,
        };
        (timer, auto_event)
    };

    let cid = client_id_from(&headers);
    broadcast_timer_stop(&state.sync, &state.db, &timer, cid.clone());
    if let Some(ev) = auto_event {
        broadcast_event_upsert(&state.sync, &state.db, &ev, cid.clone());
    }
    // Phase 1: ActivityKit `end` push to other phones' islands (no-op without APNs env).
    if let Ok(Some(fid)) = family_id_for_child(&state.db, timer.child_id) {
        state
            .apns
            .fanout_timer_end(&state.db, fid, cid.as_deref())
            .await;
    }
    Ok(Json(timer))
}


/// Active timers (`running` or `paused`), newest first.
pub async fn list_timers(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Query(q): Query<TimerQuery>,
) -> Result<Json<Vec<Timer>>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let mut out = Vec::new();
    if let Some(child_id) = q.child_id {
        if !can_access(&conn, user.id, child_id)? {
            return Err(AuthError::Unauthorized);
        }
        let mut stmt = conn
            .prepare(&format!(
                "{TIMER_SELECT} WHERE child_id = ?1 AND state IN ('running','paused') ORDER BY started_at DESC"
            ))
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![child_id.to_string()], map_timer)
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            out.push(row.map_err(|_| AuthError::Internal)?);
        }
    } else {
        let mut stmt = conn
            .prepare(
                "SELECT t.id, t.child_id, t.kind, t.started_at, t.started_by, t.state, t.stopped_at, t.updated_at, t.side, t.paused_at, t.paused_seconds
                 FROM timers t
                 JOIN children c ON c.id = t.child_id
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1 AND t.state IN ('running','paused')
                 ORDER BY t.started_at DESC",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], map_timer)
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            out.push(row.map_err(|_| AuthError::Internal)?);
        }
    }
    Ok(Json(out))
}
