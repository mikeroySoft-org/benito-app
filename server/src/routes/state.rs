use axum::{
    extract::{Query, State},
    Json,
};
use rusqlite::{params, OptionalExtension};
use serde::Deserialize;
use uuid::Uuid;

use crate::auth::{AuthError, AuthUser};
use crate::models::{BabyState, Event, Timer};
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct StateQuery {
    pub child_id: Uuid,
}

fn parse_dt(s: &str) -> rusqlite::Result<chrono::DateTime<chrono::Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&chrono::Utc))
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })
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

fn map_timer(r: &rusqlite::Row<'_>) -> rusqlite::Result<Timer> {
    Ok(Timer {
        id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        child_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(1, rusqlite::types::Type::Text, Box::new(e))
        })?,
        kind: r.get(2)?,
        started_at: parse_dt(&r.get::<_, String>(3)?)?,
        started_by: Uuid::parse_str(&r.get::<_, String>(4)?).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(4, rusqlite::types::Type::Text, Box::new(e))
        })?,
        state: r.get(5)?,
        stopped_at: r
            .get::<_, Option<String>>(6)?
            .map(|s| parse_dt(&s))
            .transpose()?,
        updated_at: parse_dt(&r.get::<_, String>(7)?)?,
        side: r.get(8)?,
        paused_at: r
            .get::<_, Option<String>>(9)?
            .map(|s| parse_dt(&s))
            .transpose()?,
        paused_seconds: r.get(10)?,
    })
}

pub async fn baby_state(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    Query(q): Query<StateQuery>,
) -> Result<Json<BabyState>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let ok: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM children c
             JOIN family_members fm ON fm.family_id = c.family_id
             WHERE c.id = ?1 AND fm.user_id = ?2",
            params![q.child_id.to_string(), user.id.to_string()],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;
    if ok.is_none() {
        return Err(AuthError::Unauthorized);
    }

    let last_feed = conn
        .query_row(
            "SELECT id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at
             FROM events WHERE child_id = ?1 AND deleted_at IS NULL AND type LIKE 'feed_%'
             ORDER BY started_at DESC LIMIT 1",
            params![q.child_id.to_string()],
            map_event,
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;

    let last_diaper = conn
        .query_row(
            "SELECT id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at
             FROM events WHERE child_id = ?1 AND deleted_at IS NULL AND type = 'diaper'
             ORDER BY started_at DESC LIMIT 1",
            params![q.child_id.to_string()],
            map_event,
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;

    let last_medicine = conn
        .query_row(
            "SELECT id, child_id, type, subtype, started_at, ended_at, amount_value, amount_unit, side, notes, payload_json, created_by, created_at, updated_at, deleted_at
             FROM events WHERE child_id = ?1 AND deleted_at IS NULL AND type = 'medicine'
             ORDER BY started_at DESC LIMIT 1",
            params![q.child_id.to_string()],
            map_event,
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;

    let active_timer = conn
        .query_row(
            "SELECT id, child_id, kind, started_at, started_by, state, stopped_at, updated_at, side, paused_at, paused_seconds
             FROM timers WHERE child_id = ?1 AND state IN ('running','paused')
             ORDER BY started_at DESC LIMIT 1",
            params![q.child_id.to_string()],
            map_timer,
        )
        .optional()
        .map_err(|_| AuthError::Internal)?;

    Ok(Json(BabyState {
        child_id: q.child_id,
        last_feed,
        last_diaper,
        active_timer,
        last_medicine,
    }))
}
