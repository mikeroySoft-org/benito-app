use axum::{
    extract::State,
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::IntoResponse,
    Json,
};
use chrono::Utc;
use rusqlite::params;
use uuid::Uuid;

use crate::auth::{AuthError, AuthUser};
use crate::models::{Child, Event, ExportBundle, Family, Timer};
use crate::AppState;

fn parse_dt(s: &str) -> rusqlite::Result<chrono::DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(s)
        .map(|d| d.with_timezone(&Utc))
        .map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })
}

pub async fn export_json(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<Json<ExportBundle>, AuthError> {
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
                    created_at: parse_dt(&r.get::<_, String>(3)?)?,
                })
            },
        )
        .ok();

    let mut children = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT c.id, c.family_id, c.name, c.birthdate, c.sex, c.created_at
                 FROM children c
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], |r| {
                Ok(Child {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    family_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            1,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    name: r.get(2)?,
                    birthdate: r.get(3)?,
                    sex: r.get(4)?,
                    created_at: parse_dt(&r.get::<_, String>(5)?)?,
                })
            })
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            children.push(row.map_err(|_| AuthError::Internal)?);
        }
    }

    let mut events = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT e.id, e.child_id, e.type, e.subtype, e.started_at, e.ended_at, e.amount_value, e.amount_unit, e.side, e.notes, e.payload_json, e.created_by, e.created_at, e.updated_at, e.deleted_at
                 FROM events e
                 JOIN children c ON c.id = e.child_id
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1
                 ORDER BY e.started_at ASC",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], |r| {
                let payload: Option<String> = r.get(10)?;
                Ok(Event {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    child_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            1,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
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
                        rusqlite::Error::FromSqlConversionFailure(
                            11,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    created_at: parse_dt(&r.get::<_, String>(12)?)?,
                    updated_at: parse_dt(&r.get::<_, String>(13)?)?,
                    deleted_at: r
                        .get::<_, Option<String>>(14)?
                        .map(|s| parse_dt(&s))
                        .transpose()?,
                })
            })
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            events.push(row.map_err(|_| AuthError::Internal)?);
        }
    }

    let mut timers = Vec::new();
    {
        let mut stmt = conn
            .prepare(
                "SELECT t.id, t.child_id, t.kind, t.started_at, t.started_by, t.state, t.stopped_at, t.updated_at, t.side, t.paused_at, t.paused_seconds
                 FROM timers t
                 JOIN children c ON c.id = t.child_id
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], |r| {
                Ok(Timer {
                    id: Uuid::parse_str(&r.get::<_, String>(0)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            0,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    child_id: Uuid::parse_str(&r.get::<_, String>(1)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            1,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
                    })?,
                    kind: r.get(2)?,
                    started_at: parse_dt(&r.get::<_, String>(3)?)?,
                    started_by: Uuid::parse_str(&r.get::<_, String>(4)?).map_err(|e| {
                        rusqlite::Error::FromSqlConversionFailure(
                            4,
                            rusqlite::types::Type::Text,
                            Box::new(e),
                        )
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
            })
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            timers.push(row.map_err(|_| AuthError::Internal)?);
        }
    }

    Ok(Json(ExportBundle {
        exported_at: Utc::now(),
        family,
        children,
        events,
        timers,
    }))
}

/// Pediatrician-friendly CSV of non-deleted events (one row per event).
pub async fn export_csv(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
) -> Result<impl IntoResponse, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let mut wtr = String::from(
        "id,child_id,type,subtype,started_at,ended_at,amount_value,amount_unit,side,notes,created_by,created_at\n",
    );
    {
        let mut stmt = conn
            .prepare(
                "SELECT e.id, e.child_id, e.type, e.subtype, e.started_at, e.ended_at, e.amount_value, e.amount_unit, e.side, e.notes, e.created_by, e.created_at
                 FROM events e
                 JOIN children c ON c.id = e.child_id
                 JOIN family_members fm ON fm.family_id = c.family_id
                 WHERE fm.user_id = ?1 AND e.deleted_at IS NULL
                 ORDER BY e.started_at ASC",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![user.id.to_string()], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, Option<String>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, Option<String>>(5)?,
                    r.get::<_, Option<f64>>(6)?,
                    r.get::<_, Option<String>>(7)?,
                    r.get::<_, Option<String>>(8)?,
                    r.get::<_, Option<String>>(9)?,
                    r.get::<_, String>(10)?,
                    r.get::<_, String>(11)?,
                ))
            })
            .map_err(|_| AuthError::Internal)?;
        for row in rows {
            let (id, child_id, ty, subtype, started, ended, amount, unit, side, notes, by, created) =
                row.map_err(|_| AuthError::Internal)?;
            wtr.push_str(&format!(
                "{},{},{},{},{},{},{},{},{},{},{},{}\n",
                csv_escape(&id),
                csv_escape(&child_id),
                csv_escape(&ty),
                csv_escape(subtype.as_deref().unwrap_or("")),
                csv_escape(&started),
                csv_escape(ended.as_deref().unwrap_or("")),
                amount.map(|v| format!("{v}")).unwrap_or_default(),
                csv_escape(unit.as_deref().unwrap_or("")),
                csv_escape(side.as_deref().unwrap_or("")),
                csv_escape(notes.as_deref().unwrap_or("")),
                csv_escape(&by),
                csv_escape(&created),
            ));
        }
    }

    let mut headers = HeaderMap::new();
    headers.insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/csv; charset=utf-8"),
    );
    headers.insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_static("attachment; filename=\"benito-events.csv\""),
    );
    Ok((StatusCode::OK, headers, wtr))
}

fn csv_escape(s: &str) -> String {
    if s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r') {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::csv_escape;

    #[test]
    fn csv_escape_preserves_plain_and_empty_values() {
        assert_eq!(csv_escape("plain value"), "plain value");
        assert_eq!(csv_escape(""), "");
    }

    #[test]
    fn csv_escape_quotes_delimiters_and_doubles_quotes() {
        assert_eq!(csv_escape("a,b"), "\"a,b\"");
        assert_eq!(csv_escape("a\"b"), "\"a\"\"b\"");
        assert_eq!(csv_escape("a\nb"), "\"a\nb\"");
        assert_eq!(csv_escape("a\rb"), "\"a\rb\"");
    }
}
