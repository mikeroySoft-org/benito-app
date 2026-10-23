//! Integration: `POST /timers/{id}/pause|resume`, pause folding on stop, and paused time
//! excluded from auto-created events and the daily summary.
use std::time::Duration;

use bytes::Bytes;
use chrono::Utc;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-pause-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let db_path = dir.join("test.db");
    let state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    let app = benito_server::build_router(state);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    tokio::time::sleep(Duration::from_millis(50)).await;
    (format!("http://{addr}"), dir)
}

async fn http_json(
    method: &str,
    url: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> Result<(u16, Value), BoxError> {
    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let mut builder = Request::builder().method(method).uri(url);
    builder = builder.header("content-type", "application/json");
    if let Some(t) = token {
        builder = builder.header("authorization", format!("Bearer {t}"));
    }
    let body_bytes = match body {
        Some(v) => Bytes::from(serde_json::to_vec(&v)?),
        None => Bytes::new(),
    };
    let req = builder.body(Full::new(body_bytes))?;
    let res = client.request(req).await?;
    let status = res.status().as_u16();
    let collected = res.into_body().collect().await?.to_bytes();
    let val = if collected.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&collected).unwrap_or(Value::String(
            String::from_utf8_lossy(&collected).into_owned(),
        ))
    };
    Ok((status, val))
}

async fn register(base: &str, name: &str, email: &str) -> String {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({ "name": name, "email": email, "password": "password123" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "register: {body}");
    body["token"].as_str().unwrap().to_string()
}

/// Registers a parent and creates a family; returns `(token, child_id)`.
async fn parent_with_child(base: &str, email: &str) -> (String, String) {
    let token = register(base, "Parent", email).await;
    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Sam" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam_body}");
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();
    (token, child_id)
}

/// Percent-encodes the RFC3339 characters that are not safe as-is in a query value.
fn enc(ts: &str) -> String {
    ts.replace('+', "%2B").replace(':', "%3A")
}

async fn get(base: &str, token: &str, path_and_query: &str) -> (u16, Value) {
    http_json("GET", &format!("{base}{path_and_query}"), Some(token), None)
        .await
        .unwrap()
}

async fn start_timer(base: &str, token: &str, child_id: &str, kind: &str, side: Option<&str>) -> Value {
    let mut body = json!({ "child_id": child_id, "kind": kind });
    if let Some(s) = side {
        body["side"] = json!(s);
    }
    let (status, timer) = http_json("POST", &format!("{base}/timers"), Some(token), Some(body))
        .await
        .unwrap();
    assert_eq!(status, 200, "start {kind}: {timer}");
    timer
}

/// `POST /timers/{id}/{action}` with an empty JSON body (as clients send).
async fn timer_action(base: &str, token: &str, id: &str, action: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/timers/{id}/{action}"),
        Some(token),
        Some(json!({})),
    )
    .await
    .unwrap()
}

/// Direct DB handle for backdating timestamps (avoids long sleeps in tests).
fn open_db(dir: &std::path::Path) -> rusqlite::Connection {
    rusqlite::Connection::open(dir.join("test.db")).unwrap()
}

fn events_of_type(events: &Value, ty: &str) -> Vec<Value> {
    events
        .as_array()
        .unwrap_or_else(|| panic!("expected array, got {events}"))
        .iter()
        .filter(|e| e["type"] == ty)
        .cloned()
        .collect()
}

#[tokio::test]
async fn pause_resume_stop_lifecycle() {
    let (base, dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let timer = start_timer(&base, &token, &child_id, "feed_breast", Some("L")).await;
    let id = timer["id"].as_str().unwrap().to_string();
    assert_eq!(timer["paused_seconds"], 0, "{timer}");
    assert!(timer["paused_at"].is_null(), "{timer}");

    // Pause: state paused, paused_at set, still the active timer.
    let (status, paused) = timer_action(&base, &token, &id, "pause").await;
    assert_eq!(status, 200, "{paused}");
    assert_eq!(paused["state"], "paused");
    assert!(paused["paused_at"].is_string(), "{paused}");
    assert_eq!(paused["paused_seconds"], 0);

    let (status, st) = get(&base, &token, &format!("/state?child_id={child_id}")).await;
    assert_eq!(status, 200, "{st}");
    assert_eq!(st["active_timer"]["id"], id.as_str(), "{st}");
    assert_eq!(st["active_timer"]["state"], "paused");

    let (status, listed) = get(&base, &token, &format!("/timers?child_id={child_id}")).await;
    assert_eq!(status, 200, "{listed}");
    assert!(
        listed.as_array().unwrap().iter().any(|t| t["id"] == id.as_str()),
        "paused timer missing from list: {listed}"
    );
    let (status, listed_all) = get(&base, &token, "/timers").await;
    assert_eq!(status, 200, "{listed_all}");
    assert!(
        listed_all.as_array().unwrap().iter().any(|t| t["id"] == id.as_str()),
        "paused timer missing from family list: {listed_all}"
    );

    let (status, again) = timer_action(&base, &token, &id, "pause").await;
    assert_eq!(status, 409, "double pause: {again}");

    tokio::time::sleep(Duration::from_millis(1100)).await;

    // Resume: completed pause folded into paused_seconds.
    let (status, resumed) = timer_action(&base, &token, &id, "resume").await;
    assert_eq!(status, 200, "{resumed}");
    assert_eq!(resumed["state"], "running");
    assert!(resumed["paused_at"].is_null(), "{resumed}");
    let after_resume = resumed["paused_seconds"].as_i64().unwrap();
    assert!(after_resume >= 1, "paused_seconds after 1.1s pause: {resumed}");

    let (status, again) = timer_action(&base, &token, &id, "resume").await;
    assert_eq!(status, 409, "double resume: {again}");

    // Pause again, backdate the open pause by 90s, then stop while paused.
    let (status, paused) = timer_action(&base, &token, &id, "pause").await;
    assert_eq!(status, 200, "{paused}");
    open_db(&dir)
        .execute(
            "UPDATE timers SET paused_at = ?2 WHERE id = ?1",
            rusqlite::params![id, (Utc::now() - chrono::Duration::seconds(90)).to_rfc3339()],
        )
        .unwrap();

    let (status, stopped) = timer_action(&base, &token, &id, "stop").await;
    assert_eq!(status, 200, "{stopped}");
    assert_eq!(stopped["state"], "stopped");
    assert!(stopped["paused_at"].is_null(), "{stopped}");
    let final_paused = stopped["paused_seconds"].as_i64().unwrap();
    assert!(
        final_paused >= after_resume + 90,
        "stop must fold the open pause: {after_resume} -> {stopped}"
    );

    let (status, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{events}");
    let feeds = events_of_type(&events, "feed_breast");
    assert_eq!(feeds.len(), 1, "{events}");
    assert_eq!(feeds[0]["side"], "L");
    assert_eq!(feeds[0]["started_at"], timer["started_at"]);
    assert_eq!(feeds[0]["payload_json"]["paused_seconds"], final_paused, "{}", feeds[0]);

    let (_, st) = get(&base, &token, &format!("/state?child_id={child_id}")).await;
    assert!(st["active_timer"].is_null(), "{st}");

    // Stopped timers can't be paused or resumed; re-stopping stays idempotent.
    let (status, _) = timer_action(&base, &token, &id, "pause").await;
    assert_eq!(status, 409);
    let (status, _) = timer_action(&base, &token, &id, "resume").await;
    assert_eq!(status, 409);
    let (status, restopped) = timer_action(&base, &token, &id, "stop").await;
    assert_eq!(status, 200, "{restopped}");
    assert_eq!(restopped["paused_seconds"], final_paused);
    let (_, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(events_of_type(&events, "feed_breast").len(), 1, "{events}");
}

#[tokio::test]
async fn stop_without_pause_has_null_payload() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let timer = start_timer(&base, &token, &child_id, "sleep", None).await;
    let id = timer["id"].as_str().unwrap();

    let (status, stopped) = timer_action(&base, &token, id, "stop").await;
    assert_eq!(status, 200, "{stopped}");
    assert_eq!(stopped["paused_seconds"], 0);

    let (_, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    let sleeps = events_of_type(&events, "sleep");
    assert_eq!(sleeps.len(), 1, "{events}");
    assert!(sleeps[0]["payload_json"].is_null(), "{}", sleeps[0]);
}

#[tokio::test]
async fn summary_sleep_hours_exclude_paused_time() {
    let (base, dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let timer = start_timer(&base, &token, &child_id, "sleep", None).await;
    let id = timer["id"].as_str().unwrap().to_string();

    // A 2h nap with a 30min pause still open at stop → 1.5h of sleep.
    let now = Utc::now();
    open_db(&dir)
        .execute(
            "UPDATE timers SET started_at = ?2 WHERE id = ?1",
            rusqlite::params![id, (now - chrono::Duration::hours(2)).to_rfc3339()],
        )
        .unwrap();
    let (status, paused) = timer_action(&base, &token, &id, "pause").await;
    assert_eq!(status, 200, "{paused}");
    open_db(&dir)
        .execute(
            "UPDATE timers SET paused_at = ?2 WHERE id = ?1",
            rusqlite::params![id, (now - chrono::Duration::minutes(30)).to_rfc3339()],
        )
        .unwrap();
    let (status, stopped) = timer_action(&base, &token, &id, "stop").await;
    assert_eq!(status, 200, "{stopped}");
    let paused_secs = stopped["paused_seconds"].as_i64().unwrap();
    assert!((1800..1810).contains(&paused_secs), "{stopped}");

    let from = enc(&(now - chrono::Duration::hours(3)).to_rfc3339());
    let to = enc(&(now + chrono::Duration::minutes(1)).to_rfc3339());
    let (status, summary) = get(
        &base,
        &token,
        &format!("/summary/daily?child_id={child_id}&from={from}&to={to}"),
    )
    .await;
    assert_eq!(status, 200, "{summary}");
    assert_eq!(summary["sleep_event_count"], 1, "{summary}");
    let hours = summary["sleep_hours"].as_f64().unwrap();
    assert!((hours - 1.5).abs() < 0.02, "sleep_hours should exclude pause: {summary}");
}

#[tokio::test]
async fn pause_resume_are_family_scoped_and_404_unknown() {
    let (base, _dir) = spawn_server().await;
    let (token_a, child_a) = parent_with_child(&base, "a@example.com").await;
    let (token_b, _child_b) = parent_with_child(&base, "b@example.com").await;
    let timer = start_timer(&base, &token_a, &child_a, "sleep", None).await;
    let id = timer["id"].as_str().unwrap();

    let (status, body) = timer_action(&base, &token_b, id, "pause").await;
    assert_eq!(status, 401, "other family pause: {body}");

    let (status, paused) = timer_action(&base, &token_a, id, "pause").await;
    assert_eq!(status, 200, "{paused}");
    let (status, body) = timer_action(&base, &token_b, id, "resume").await;
    assert_eq!(status, 401, "other family resume: {body}");

    let unknown = uuid::Uuid::new_v4().to_string();
    let (status, _) = timer_action(&base, &token_a, &unknown, "pause").await;
    assert_eq!(status, 404);
    let (status, _) = timer_action(&base, &token_a, &unknown, "resume").await;
    assert_eq!(status, 404);
}

#[tokio::test]
async fn client_at_is_stored_as_timer_wall_times() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "clock@example.com").await;

    // Phone ~53s ahead of a typical server — store phone times so elapsed(Date()) ≈ 0.
    let phone_start = (Utc::now() + chrono::Duration::seconds(53))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let (status, timer) = http_json(
        "POST",
        &format!("{base}/timers"),
        Some(&token),
        Some(json!({
            "child_id": child_id,
            "kind": "feed_breast",
            "side": "L",
            "at": phone_start,
        })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{timer}");
    let started = chrono::DateTime::parse_from_rfc3339(timer["started_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    let expected_start = chrono::DateTime::parse_from_rfc3339(&phone_start)
        .unwrap()
        .with_timezone(&Utc);
    assert_eq!(started, expected_start, "{timer}");
    let id = timer["id"].as_str().unwrap().to_string();

    let phone_pause = (Utc::now() + chrono::Duration::seconds(53 + 120))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let (status, paused) = http_json(
        "POST",
        &format!("{base}/timers/{id}/pause"),
        Some(&token),
        Some(json!({ "at": phone_pause })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{paused}");
    assert_eq!(paused["state"], "paused");
    let paused_at = chrono::DateTime::parse_from_rfc3339(paused["paused_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    let expected_pause = chrono::DateTime::parse_from_rfc3339(&phone_pause)
        .unwrap()
        .with_timezone(&Utc);
    assert_eq!(paused_at, expected_pause, "{paused}");

    let phone_resume = (Utc::now() + chrono::Duration::seconds(53 + 180))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    let (status, resumed) = http_json(
        "POST",
        &format!("{base}/timers/{id}/resume"),
        Some(&token),
        Some(json!({ "at": phone_resume })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{resumed}");
    assert_eq!(resumed["state"], "running");
    assert!(resumed["paused_at"].is_null(), "{resumed}");
    // ~60s pause from phone_pause → phone_resume
    assert_eq!(resumed["paused_seconds"], 60, "{resumed}");
}


/// Overnight sleep 22:00→02:00: day-of-start and day-of-wake each get ~2h (clipped overlap).
#[tokio::test]
async fn summary_overnight_sleep_is_clipped_per_day() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "overnight@example.com").await;

    // Fixed UTC anchors so the assertion does not depend on wall-clock "now".
    let day0 = chrono::NaiveDate::from_ymd_opt(2026, 10, 5)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();
    let day1 = day0 + chrono::Duration::days(1);
    let day2 = day0 + chrono::Duration::days(2);
    let sleep_start = day0 + chrono::Duration::hours(22);
    let sleep_end = day1 + chrono::Duration::hours(2);

    let (status, created) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&token),
        Some(json!({
            "child_id": child_id,
            "type": "sleep",
            "started_at": sleep_start.to_rfc3339(),
            "ended_at": sleep_end.to_rfc3339(),
        })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{created}");

    let from0 = enc(&day0.to_rfc3339());
    let to0 = enc(&day1.to_rfc3339());
    let (status, start_day) = get(
        &base,
        &token,
        &format!("/summary/daily?child_id={child_id}&from={from0}&to={to0}"),
    )
    .await;
    assert_eq!(status, 200, "{start_day}");
    assert_eq!(start_day["sleep_event_count"], 1, "{start_day}");
    let hours0 = start_day["sleep_hours"].as_f64().unwrap();
    assert!(
        (hours0 - 2.0).abs() < 0.02,
        "day-of-start should clip ~2h, got {hours0}: {start_day}"
    );

    let from1 = enc(&day1.to_rfc3339());
    let to1 = enc(&day2.to_rfc3339());
    let (status, wake_day) = get(
        &base,
        &token,
        &format!("/summary/daily?child_id={child_id}&from={from1}&to={to1}"),
    )
    .await;
    assert_eq!(status, 200, "{wake_day}");
    assert_eq!(wake_day["sleep_event_count"], 1, "{wake_day}");
    let hours1 = wake_day["sleep_hours"].as_f64().unwrap();
    assert!(
        (hours1 - 2.0).abs() < 0.02,
        "day-of-wake should clip ~2h, got {hours1}: {wake_day}"
    );
}

/// Nursing 23:50→00:10 splits 10 min / 10 min across days; bottles keep oz and ml apart.
#[tokio::test]
async fn summary_nursing_seconds_clip_per_day_and_bottle_totals() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "fedtoday@example.com").await;

    let day0 = chrono::NaiveDate::from_ymd_opt(2026, 10, 5)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();
    let day1 = day0 + chrono::Duration::days(1);
    let day2 = day0 + chrono::Duration::days(2);

    let post = |body: Value| {
        let base = base.clone();
        let token = token.clone();
        async move {
            let (status, created) =
                http_json("POST", &format!("{base}/events"), Some(&token), Some(body)).await.unwrap();
            assert_eq!(status, 200, "{created}");
        }
    };
    // Straddles midnight.
    post(json!({
        "child_id": child_id, "type": "feed_breast", "side": "L",
        "started_at": (day0 + chrono::Duration::minutes(23 * 60 + 50)).to_rfc3339(),
        "ended_at": (day1 + chrono::Duration::minutes(10)).to_rfc3339(),
    }))
    .await;
    // Fully inside day0: 15 min.
    post(json!({
        "child_id": child_id, "type": "feed_breast", "side": "R",
        "started_at": (day0 + chrono::Duration::hours(9)).to_rfc3339(),
        "ended_at": (day0 + chrono::Duration::minutes(9 * 60 + 15)).to_rfc3339(),
    }))
    .await;
    post(json!({
        "child_id": child_id, "type": "feed_bottle", "amount_value": 3.0, "amount_unit": "oz",
        "started_at": (day0 + chrono::Duration::hours(12)).to_rfc3339(),
    }))
    .await;
    post(json!({
        "child_id": child_id, "type": "feed_bottle", "amount_value": 60.0, "amount_unit": "ml",
        "started_at": (day0 + chrono::Duration::hours(15)).to_rfc3339(),
    }))
    .await;

    let summary = |from: chrono::DateTime<chrono::Utc>, to: chrono::DateTime<chrono::Utc>| {
        let base = base.clone();
        let token = token.clone();
        let child_id = child_id.clone();
        async move {
            let (status, s) = get(
                &base,
                &token,
                &format!(
                    "/summary/daily?child_id={child_id}&from={}&to={}",
                    enc(&from.to_rfc3339()),
                    enc(&to.to_rfc3339())
                ),
            )
            .await;
            assert_eq!(status, 200, "{s}");
            s
        }
    };

    let d0 = summary(day0, day1).await;
    let nursing0 = d0["nursing_seconds"].as_f64().unwrap();
    assert!((nursing0 - 25.0 * 60.0).abs() < 1.0, "day0 nursing 15+10 min: {d0}");
    assert_eq!(d0["bottle_oz_total"].as_f64().unwrap(), 3.0, "{d0}");
    assert_eq!(d0["bottle_ml_total"].as_f64().unwrap(), 60.0, "{d0}");

    let d1 = summary(day1, day2).await;
    let nursing1 = d1["nursing_seconds"].as_f64().unwrap();
    assert!((nursing1 - 10.0 * 60.0).abs() < 1.0, "day1 gets the 10 min after midnight: {d1}");
    assert_eq!(d1["bottle_oz_equiv"].as_f64().unwrap(), 0.0, "{d1}");
}
