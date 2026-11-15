//! Pediatrician-oriented daily summary.
//!
//! Day bounds: prefer explicit `from`/`to` (RFC3339). Else `day=YYYY-MM-DD` as a UTC
//! calendar day. Else last 24 hours from now. The iOS app always sends `from`/`to` set to
//! the device's local midnight → next midnight.
//!
//! Durations (nursing, crying, sleep) only come from events with an `ended_at`. Running
//! sessions live in `timers`; stopping one writes the event with its end. An event with no
//! `ended_at` is a one-off log with no known duration and adds no time.

use axum::{extract::State, Json};
use chrono::{DateTime, Duration, NaiveDate, TimeZone, Utc};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::{AuthError, AuthUser};
use crate::AppState;

#[derive(Debug, Deserialize)]
pub struct DailySummaryQuery {
    pub child_id: Uuid,
    /// UTC calendar day `YYYY-MM-DD` (ignored when from/to set).
    pub day: Option<String>,
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct DailySummary {
    pub child_id: Uuid,
    pub from: DateTime<Utc>,
    pub to: DateTime<Utc>,
    pub day: Option<String>,
    pub feed_breast_count: i64,
    pub feed_breast_left: i64,
    pub feed_breast_right: i64,
    pub feed_bottle_count: i64,
    pub bottle_oz_total: f64,
    pub bottle_ml_total: f64,
    /// oz + ml converted (1 oz ≈ 29.5735 ml) for a single pediatrician figure.
    pub bottle_oz_equiv: f64,
    pub feed_solid_count: i64,
    /// Sum of timed feed durations (started_at+ended_at), excluding paused_seconds.
    pub feed_seconds: f64,
    /// Nursing (`feed_breast`) seconds overlapping [from, to), clipped to the window like
    /// sleep, so a feed straddling midnight splits across both days.
    pub nursing_seconds: f64,
    /// Crying (`activity` / `crying`) seconds overlapping [from, to), clipped and
    /// pause-adjusted the same way as nursing.
    pub crying_seconds: f64,
    pub diaper_wet: i64,
    pub diaper_dirty: i64,
    pub diaper_both: i64,
    pub diaper_other: i64,
    pub sleep_event_count: i64,
    /// Sum of sleep durations in hours for events overlapping [from, to), clipped to the
    /// window and excluding paused time recorded in `payload_json.paused_seconds`.
    pub sleep_hours: f64,
    pub pump_count: i64,
    pub medicine_count: i64,
    pub total_events: i64,
}

fn ensure_child_access(
    conn: &rusqlite::Connection,
    user_id: Uuid,
    child_id: Uuid,
) -> Result<(), AuthError> {
    let ok: Option<i64> = conn
        .query_row(
            "SELECT 1 FROM children c
             JOIN family_members fm ON fm.family_id = c.family_id
             WHERE c.id = ?1 AND fm.user_id = ?2 LIMIT 1",
            params![child_id.to_string(), user_id.to_string()],
            |r| r.get(0),
        )
        .optional_row()
        .map_err(|_| AuthError::Internal)?;
    if ok.is_none() {
        return Err(AuthError::NotFound("child not found".into()));
    }
    Ok(())
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

type SummaryWindow = (DateTime<Utc>, DateTime<Utc>, Option<String>);

fn resolve_window(q: &DailySummaryQuery) -> Result<SummaryWindow, AuthError> {
    if let (Some(from), Some(to)) = (q.from, q.to) {
        if to <= from {
            return Err(AuthError::BadRequest("to must be after from".into()));
        }
        return Ok((from, to, q.day.clone()));
    }
    if let Some(day) = &q.day {
        let nd = NaiveDate::parse_from_str(day, "%Y-%m-%d")
            .map_err(|_| AuthError::BadRequest("day must be YYYY-MM-DD".into()))?;
        let from = Utc.from_utc_datetime(&nd.and_hms_opt(0, 0, 0).unwrap());
        let to = from + Duration::days(1);
        return Ok((from, to, Some(day.clone())));
    }
    let to = Utc::now();
    let from = to - Duration::hours(24);
    Ok((from, to, None))
}

/// `paused_seconds` from an event's `payload_json` (set when a paused timer stopped); 0 if absent.
fn paused_seconds(payload: Option<&str>) -> i64 {
    payload
        .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
        .and_then(|v| v.get("paused_seconds").and_then(|n| n.as_i64()))
        .unwrap_or(0)
        .max(0)
}

/// Wall-clock duration minus paused time for a fully-contained timed event; 0 if open-ended / unparseable.
fn timed_event_secs(ended: Option<&str>, payload: Option<&str>, started: &str) -> f64 {
    let (Ok(s), Some(e_s)) = (
        DateTime::parse_from_rfc3339(started).map(|d| d.with_timezone(&Utc)),
        ended,
    ) else {
        return 0.0;
    };
    let Ok(e) = DateTime::parse_from_rfc3339(e_s) else {
        return 0.0;
    };
    let secs = (e.with_timezone(&Utc) - s).num_seconds() - paused_seconds(payload);
    secs.max(0) as f64
}

/// Active seconds of `[start, end]` inside `[from, to)`. When `paused` is opaque, scale it by the
/// clipped/wall ratio so a pause does not wipe an overnight clip.
fn clipped_active_secs(
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
    paused: i64,
) -> f64 {
    let clip_start = if start > from { start } else { from };
    let clip_end = if end < to { end } else { to };
    if clip_end <= clip_start {
        return 0.0;
    }
    let wall = (end - start).num_seconds().max(0) as f64;
    let clipped_wall = (clip_end - clip_start).num_seconds().max(0) as f64;
    if wall <= 0.0 {
        return 0.0;
    }
    let active_full = (wall - paused.max(0) as f64).max(0.0);
    clipped_wall * active_full / wall
}

/// A timed event's wall-clock span plus its recorded pause total.
struct EventSpan {
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    paused: i64,
}

impl EventSpan {
    fn clipped_active_secs(&self, from: DateTime<Utc>, to: DateTime<Utc>) -> f64 {
        clipped_active_secs(self.start, self.end, from, to, self.paused)
    }
}

/// Finished events of `event_type` overlapping [from, to). Events without `ended_at` are
/// skipped: treating them as running until now made a forgotten Sep 27 nursing log count
/// as nursing from midnight to now on every later day.
fn overlapping_spans(
    conn: &rusqlite::Connection,
    child: &str,
    event_type: &str,
    subtype: Option<&str>,
    from: DateTime<Utc>,
    to: DateTime<Utc>,
) -> Result<Vec<EventSpan>, AuthError> {
    let mut stmt = conn
        .prepare(
            "SELECT started_at, ended_at, payload_json
             FROM events
             WHERE child_id = ?1
               AND deleted_at IS NULL
               AND type = ?4
               AND (?5 IS NULL OR subtype = ?5)
               AND started_at < ?3
               AND ended_at IS NOT NULL
               AND ended_at > ?2",
        )
        .map_err(|_| AuthError::Internal)?;
    let rows = stmt
        .query_map(
            params![
                child,
                from.to_rfc3339(),
                to.to_rfc3339(),
                event_type,
                subtype
            ],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .map_err(|_| AuthError::Internal)?;

    let mut spans = Vec::new();
    for row in rows {
        let (started, ended, payload) = row.map_err(|_| AuthError::Internal)?;
        let Ok(start) = DateTime::parse_from_rfc3339(&started).map(|d| d.with_timezone(&Utc))
        else {
            continue;
        };
        let Ok(end) = DateTime::parse_from_rfc3339(&ended).map(|d| d.with_timezone(&Utc)) else {
            continue;
        };
        if end <= start {
            continue;
        }
        spans.push(EventSpan {
            start,
            end,
            paused: paused_seconds(payload.as_deref()),
        });
    }
    Ok(spans)
}

pub async fn daily_summary(
    State(state): State<AppState>,
    AuthUser(user): AuthUser,
    axum::extract::Query(q): axum::extract::Query<DailySummaryQuery>,
) -> Result<Json<DailySummary>, AuthError> {
    let (from, to, day_label) = resolve_window(&q)?;
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    ensure_child_access(&conn, user.id, q.child_id)?;

    let from_s = from.to_rfc3339();
    let to_s = to.to_rfc3339();
    let child = q.child_id.to_string();

    let mut feed_breast_count = 0i64;
    let mut feed_breast_left = 0i64;
    let mut feed_breast_right = 0i64;
    let mut feed_bottle_count = 0i64;
    let mut bottle_oz_total = 0.0f64;
    let mut bottle_ml_total = 0.0f64;
    let mut feed_solid_count = 0i64;
    let mut diaper_wet = 0i64;
    let mut diaper_dirty = 0i64;
    let mut diaper_both = 0i64;
    let mut diaper_other = 0i64;
    let mut feed_secs = 0.0f64;
    let mut sleep_event_count = 0i64;
    let mut sleep_secs = 0.0f64;
    let mut pump_count = 0i64;
    let mut medicine_count = 0i64;
    let mut total_events = 0i64;

    // Point-in-time / started-in-window events (feeds, diapers, …). Sleep is handled
    // separately with an overlap query so overnight naps that started yesterday still
    // contribute the clipped portion inside [from, to).
    {
        let mut stmt = conn
            .prepare(
                "SELECT type, subtype, side, amount_value, amount_unit, started_at, ended_at, payload_json
                 FROM events
                 WHERE child_id = ?1
                   AND deleted_at IS NULL
                   AND started_at >= ?2
                   AND started_at < ?3",
            )
            .map_err(|_| AuthError::Internal)?;
        let rows = stmt
            .query_map(params![child, from_s, to_s], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, Option<String>>(1)?,
                    r.get::<_, Option<String>>(2)?,
                    r.get::<_, Option<f64>>(3)?,
                    r.get::<_, Option<String>>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, Option<String>>(6)?,
                    r.get::<_, Option<String>>(7)?,
                ))
            })
            .map_err(|_| AuthError::Internal)?;

        for row in rows {
            let (ty, subtype, side, amount, unit, started, ended, payload) =
                row.map_err(|_| AuthError::Internal)?;
            total_events += 1;
            match ty.as_str() {
                "feed_breast" => {
                    feed_breast_count += 1;
                    match side.as_deref() {
                        Some("L") | Some("l") | Some("left") => feed_breast_left += 1,
                        Some("R") | Some("r") | Some("right") => feed_breast_right += 1,
                        _ => {}
                    }
                    feed_secs +=
                        timed_event_secs(ended.as_deref(), payload.as_deref(), started.as_str());
                }
                "feed_bottle" => {
                    feed_bottle_count += 1;
                    if let Some(v) = amount {
                        match unit
                            .as_deref()
                            .unwrap_or("oz")
                            .to_ascii_lowercase()
                            .as_str()
                        {
                            "ml" => bottle_ml_total += v,
                            _ => bottle_oz_total += v,
                        }
                    }
                    feed_secs +=
                        timed_event_secs(ended.as_deref(), payload.as_deref(), started.as_str());
                }
                "feed_solid" => {
                    feed_solid_count += 1;
                    feed_secs +=
                        timed_event_secs(ended.as_deref(), payload.as_deref(), started.as_str());
                }
                "diaper" => match subtype
                    .as_deref()
                    .unwrap_or("")
                    .to_ascii_lowercase()
                    .as_str()
                {
                    "wet" => diaper_wet += 1,
                    "dirty" | "poop" | "bm" => diaper_dirty += 1,
                    "both" | "mixed" => diaper_both += 1,
                    _ => diaper_other += 1,
                },
                "sleep" => {
                    // Counted + duration via overlap query below (avoids double-count).
                }
                "pump" => pump_count += 1,
                "medicine" => medicine_count += 1,
                _ => {}
            }
        }
    }

    // Sleep: any event overlapping [from, to). Duration is the clipped intersection,
    // with paused_seconds scaled proportionally when the pause timeline is opaque.
    for span in overlapping_spans(&conn, &child, "sleep", None, from, to)? {
        // Overnight sleep that started before `from` is not in the started-in-window
        // scan above — fold it into total_events here.
        if span.start < from {
            total_events += 1;
        }
        sleep_event_count += 1;
        sleep_secs += span.clipped_active_secs(from, to);
    }

    // Nursing minutes use the same overlap clip (counts stay started-in-window above).
    let clipped_total = |event_type: &str, subtype: Option<&str>| -> Result<f64, AuthError> {
        Ok(
            overlapping_spans(&conn, &child, event_type, subtype, from, to)?
                .iter()
                .map(|span| span.clipped_active_secs(from, to))
                .sum(),
        )
    };
    let nursing_secs = clipped_total("feed_breast", None)?;
    let crying_secs = clipped_total("activity", Some("crying"))?;

    // 1 oz ≈ 29.5735 ml
    let bottle_oz_equiv = bottle_oz_total + (bottle_ml_total / 29.5735);

    Ok(Json(DailySummary {
        child_id: q.child_id,
        from,
        to,
        day: day_label,
        feed_breast_count,
        feed_breast_left,
        feed_breast_right,
        feed_bottle_count,
        bottle_oz_total: (bottle_oz_total * 100.0).round() / 100.0,
        bottle_ml_total: (bottle_ml_total * 100.0).round() / 100.0,
        bottle_oz_equiv: (bottle_oz_equiv * 100.0).round() / 100.0,
        feed_solid_count,
        feed_seconds: (feed_secs * 100.0).round() / 100.0,
        nursing_seconds: (nursing_secs * 100.0).round() / 100.0,
        crying_seconds: (crying_secs * 100.0).round() / 100.0,
        diaper_wet,
        diaper_dirty,
        diaper_both,
        diaper_other,
        sleep_event_count,
        sleep_hours: (sleep_secs / 3600.0 * 100.0).round() / 100.0,
        pump_count,
        medicine_count,
        total_events,
    }))
}
