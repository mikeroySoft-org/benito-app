//! Integration: editing/deleting logged events (`PATCH|DELETE /events/{id}`), moving an
//! active timer's start (`PATCH /timers/{id}`), and sliding session expiry.
use std::time::Duration;

use bytes::Bytes;
use chrono::{DateTime, Utc};
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-edit-{}", uuid::Uuid::new_v4()));
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

async fn get(base: &str, token: &str, path_and_query: &str) -> (u16, Value) {
    http_json("GET", &format!("{base}{path_and_query}"), Some(token), None)
        .await
        .unwrap()
}

async fn patch(base: &str, token: &str, path: &str, body: Value) -> (u16, Value) {
    http_json("PATCH", &format!("{base}{path}"), Some(token), Some(body))
        .await
        .unwrap()
}

async fn create_event(base: &str, token: &str, body: Value) -> Value {
    let (status, event) = http_json("POST", &format!("{base}/events"), Some(token), Some(body))
        .await
        .unwrap();
    assert_eq!(status, 200, "create event: {event}");
    event
}

async fn start_timer(
    base: &str,
    token: &str,
    child_id: &str,
    kind: &str,
    side: Option<&str>,
) -> Value {
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

fn ts(v: &Value) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(
        v.as_str()
            .unwrap_or_else(|| panic!("expected timestamp, got {v}")),
    )
    .unwrap()
    .with_timezone(&Utc)
}

fn session_expiry(dir: &std::path::Path, token: &str) -> String {
    open_db(dir)
        .query_row(
            "SELECT expires_at FROM sessions WHERE token = ?1",
            rusqlite::params![token],
            |r| r.get(0),
        )
        .unwrap()
}

fn set_session_expiry(dir: &std::path::Path, token: &str, expires_at: &str) {
    open_db(dir)
        .execute(
            "UPDATE sessions SET expires_at = ?2 WHERE token = ?1",
            rusqlite::params![token, expires_at],
        )
        .unwrap();
}

#[tokio::test]
async fn edit_event_times_validated() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let now = Utc::now();
    let started = now - chrono::Duration::hours(1);
    let ended = now - chrono::Duration::minutes(30);
    let sleep = create_event(
        &base,
        &token,
        json!({
            "child_id": child_id,
            "type": "sleep",
            "started_at": started.to_rfc3339(),
            "ended_at": ended.to_rfc3339(),
        }),
    )
    .await;
    let path = format!("/events/{}", sleep["id"].as_str().unwrap());

    // Moving the start earlier keeps the existing end and is reflected in the response.
    let earlier = now - chrono::Duration::hours(2);
    let (status, edited) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": earlier.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 200, "{edited}");
    assert_eq!(ts(&edited["started_at"]), earlier, "{edited}");
    assert_eq!(ts(&edited["ended_at"]), ended, "{edited}");

    // End before (resulting) start → 400, whether the bad side is the new end or the new start.
    let before_start = earlier - chrono::Duration::minutes(5);
    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "ended_at": before_start.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "ended before started: {body}");
    let after_end = ended + chrono::Duration::minutes(1);
    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": after_end.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "started after existing end: {body}");

    // Start an hour in the future → 400.
    let future = now + chrono::Duration::hours(1);
    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": future.to_rfc3339(), "ended_at": (future + chrono::Duration::minutes(10)).to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "future start: {body}");

    // Rejected edits left the row untouched.
    let (_, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    let row = events
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == sleep["id"])
        .unwrap_or_else(|| panic!("edited event missing: {events}"));
    assert_eq!(ts(&row["started_at"]), earlier, "{row}");
    assert_eq!(ts(&row["ended_at"]), ended, "{row}");
}

#[tokio::test]
async fn edit_bottle_amount_and_delete() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let bottle = create_event(
        &base,
        &token,
        json!({
            "child_id": child_id,
            "type": "feed_bottle",
            "subtype": "formula",
            "amount_value": 3.0,
            "amount_unit": "oz",
        }),
    )
    .await;
    let id = bottle["id"].as_str().unwrap().to_string();
    let path = format!("/events/{id}");

    let (status, edited) = patch(
        &base,
        &token,
        &path,
        json!({ "amount_value": 4.5, "subtype": "breastmilk" }),
    )
    .await;
    assert_eq!(status, 200, "{edited}");
    assert_eq!(edited["amount_value"], 4.5, "{edited}");
    assert_eq!(edited["subtype"], "breastmilk", "{edited}");
    assert_eq!(edited["amount_unit"], "oz", "{edited}");
    assert_eq!(edited["started_at"], bottle["started_at"], "{edited}");

    let (status, body) = http_json("DELETE", &format!("{base}{path}"), Some(&token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{body}");
    let (status, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{events}");
    assert!(
        !events
            .as_array()
            .unwrap()
            .iter()
            .any(|e| e["id"] == id.as_str()),
        "deleted event still listed: {events}"
    );
    let (status, _) = patch(&base, &token, &path, json!({ "notes": "x" })).await;
    assert_eq!(status, 404, "editing a deleted event");
}

#[tokio::test]
async fn adjust_running_timer_start_carries_into_auto_event() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let timer = start_timer(&base, &token, &child_id, "feed_breast", Some("L")).await;
    let id = timer["id"].as_str().unwrap().to_string();
    let path = format!("/timers/{id}");
    let now = Utc::now();

    let ten_ago = now - chrono::Duration::minutes(10);
    let (status, adjusted) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": ten_ago.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 200, "{adjusted}");
    assert_eq!(ts(&adjusted["started_at"]), ten_ago, "{adjusted}");
    assert_eq!(adjusted["state"], "running");

    let (status, st) = get(&base, &token, &format!("/state?child_id={child_id}")).await;
    assert_eq!(status, 200, "{st}");
    assert_eq!(st["active_timer"]["id"], id.as_str(), "{st}");
    assert_eq!(ts(&st["active_timer"]["started_at"]), ten_ago, "{st}");

    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": (now + chrono::Duration::minutes(10)).to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "future start: {body}");
    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": (now - chrono::Duration::hours(25)).to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "start over 24h ago: {body}");

    let (status, stopped) = timer_action(&base, &token, &id, "stop").await;
    assert_eq!(status, 200, "{stopped}");
    let (_, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    let feeds: Vec<&Value> = events
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["type"] == "feed_breast")
        .collect();
    assert_eq!(feeds.len(), 1, "{events}");
    assert_eq!(ts(&feeds[0]["started_at"]), ten_ago, "{}", feeds[0]);

    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": (now - chrono::Duration::minutes(20)).to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 409, "stopped timer: {body}");
}

#[tokio::test]
async fn adjust_paused_timer_and_access_rules() {
    let (base, dir) = spawn_server().await;
    let (token_a, child_a) = parent_with_child(&base, "a@example.com").await;
    let (token_b, _child_b) = parent_with_child(&base, "b@example.com").await;
    let timer = start_timer(&base, &token_a, &child_a, "sleep", None).await;
    let id = timer["id"].as_str().unwrap().to_string();
    let path = format!("/timers/{id}");
    let now = Utc::now();

    // Paused 5 minutes ago: a start after the pause is rejected, one before it is accepted.
    let (status, paused) = timer_action(&base, &token_a, &id, "pause").await;
    assert_eq!(status, 200, "{paused}");
    let paused_at = now - chrono::Duration::minutes(5);
    open_db(&dir)
        .execute(
            "UPDATE timers SET paused_at = ?2 WHERE id = ?1",
            rusqlite::params![id, paused_at.to_rfc3339()],
        )
        .unwrap();
    let (status, body) = patch(
        &base,
        &token_a,
        &path,
        json!({ "started_at": (now - chrono::Duration::minutes(2)).to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "start after paused_at: {body}");
    let thirty_ago = now - chrono::Duration::minutes(30);
    let (status, adjusted) = patch(
        &base,
        &token_a,
        &path,
        json!({ "started_at": thirty_ago.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 200, "{adjusted}");
    assert_eq!(adjusted["state"], "paused", "{adjusted}");
    assert_eq!(ts(&adjusted["started_at"]), thirty_ago, "{adjusted}");

    let (status, body) = patch(
        &base,
        &token_b,
        &path,
        json!({ "started_at": thirty_ago.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 401, "other family: {body}");

    let unknown = format!("/timers/{}", uuid::Uuid::new_v4());
    let (status, body) = patch(
        &base,
        &token_a,
        &unknown,
        json!({ "started_at": thirty_ago.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 404, "unknown timer: {body}");
}

#[tokio::test]
async fn adjust_start_bounds_follow_phone_clock() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let timer = start_timer(&base, &token, &child_id, "sleep", None).await;
    let id = timer["id"].as_str().unwrap().to_string();
    let path = format!("/timers/{id}");
    let phone_now = Utc::now() + chrono::Duration::minutes(3);

    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": phone_now.to_rfc3339() }),
    )
    .await;
    assert_eq!(
        status, 400,
        "phone-now without at is in the server future: {body}"
    );

    let (status, adjusted) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": phone_now.to_rfc3339(), "at": phone_now.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 200, "{adjusted}");
    assert_eq!(ts(&adjusted["started_at"]), phone_now, "{adjusted}");

    let too_far = phone_now + chrono::Duration::minutes(2);
    let (status, body) = patch(
        &base,
        &token,
        &path,
        json!({ "started_at": too_far.to_rfc3339(), "at": phone_now.to_rfc3339() }),
    )
    .await;
    assert_eq!(status, 400, "more than 1 min past phone now: {body}");
}

#[tokio::test]
async fn sessions_slide_when_close_to_expiry() {
    let (base, dir) = spawn_server().await;
    let (token, _child) = parent_with_child(&base, "a@example.com").await;

    // 10 days left → renewed to ~30 days from now on use.
    set_session_expiry(
        &dir,
        &token,
        &(Utc::now() + chrono::Duration::days(10)).to_rfc3339(),
    );
    let (status, me) = get(&base, &token, "/me").await;
    assert_eq!(status, 200, "{me}");
    let renewed = DateTime::parse_from_rfc3339(&session_expiry(&dir, &token))
        .unwrap()
        .with_timezone(&Utc);
    let target = Utc::now() + chrono::Duration::days(30);
    assert!(
        (renewed - target).num_seconds().abs() < 60,
        "expected ~now+30d, got {renewed}"
    );

    // 20 days left → untouched.
    let twenty = (Utc::now() + chrono::Duration::days(20)).to_rfc3339();
    set_session_expiry(&dir, &token, &twenty);
    let (status, me) = get(&base, &token, "/me").await;
    assert_eq!(status, 200, "{me}");
    assert_eq!(session_expiry(&dir, &token), twenty);
}

#[tokio::test]
async fn expired_sessions_stay_expired() {
    let (base, dir) = spawn_server().await;
    let (token, _child) = parent_with_child(&base, "a@example.com").await;
    let expired = (Utc::now() - chrono::Duration::hours(1)).to_rfc3339();
    set_session_expiry(&dir, &token, &expired);

    let (status, body) = get(&base, &token, "/me").await;
    assert_eq!(status, 401, "{body}");
    assert_eq!(session_expiry(&dir, &token), expired);
    let (status, body) = get(&base, &token, "/me").await;
    assert_eq!(status, 401, "{body}");
}
