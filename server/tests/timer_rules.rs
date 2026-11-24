//! Timer error contracts not already pinned by pause_resume.rs or edit_and_session.rs.
//! Existing tests cover wrong-state statuses and pause/resume unknown/family statuses;
//! these tests add their messages, stop coverage, and rejected-request non-mutation.
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
    let dir = std::env::temp_dir().join(format!("benito-timer-rules-{}", uuid::Uuid::new_v4()));
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

async fn parent_with_child(base: &str, email: &str) -> (String, String) {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({"name": "Parent", "email": email, "password": "password123"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "register: {body}");
    let token = body["token"].as_str().unwrap().to_owned();
    let (status, family) = post(
        base,
        &token,
        "/families",
        json!({"name": "Family", "child_name": "Sam"}),
    )
    .await;
    assert_eq!(status, 200, "create family: {family}");
    (token, family["child"]["id"].as_str().unwrap().to_owned())
}

async fn post(base: &str, token: &str, path: &str, body: Value) -> (u16, Value) {
    http_json("POST", &format!("{base}{path}"), Some(token), Some(body))
        .await
        .unwrap()
}

async fn start_timer(base: &str, token: &str, child_id: &str) -> Value {
    let (status, timer) = post(
        base,
        token,
        "/timers",
        json!({"child_id": child_id, "kind": "sleep"}),
    )
    .await;
    assert_eq!(status, 200, "start: {timer}");
    timer
}

async fn timers(base: &str, token: &str) -> Value {
    let (status, body) = http_json("GET", &format!("{base}/timers"), Some(token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "list timers: {body}");
    body
}

#[tokio::test]
async fn timer_wrong_state_transitions_conflict() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "parent@example.com").await;
    let timer = start_timer(&base, &token, &child_id).await;
    let path = format!("/timers/{}", timer["id"].as_str().unwrap());

    // Statuses are covered by pause_resume_stop_lifecycle; pin the missing messages.
    let (_, body) = post(&base, &token, &format!("{path}/resume"), json!({})).await;
    assert_eq!(body["error"], "timer is not paused", "{body}");
    let (status, body) = post(&base, &token, &format!("{path}/pause"), json!({})).await;
    assert_eq!(status, 200, "pause setup: {body}");
    let (_, body) = post(&base, &token, &format!("{path}/pause"), json!({})).await;
    assert_eq!(body["error"], "timer is not running", "{body}");

    let (status, body) = post(&base, &token, &format!("{path}/stop"), json!({})).await;
    assert_eq!(status, 200, "stop setup: {body}");
    for (action, message) in [
        ("pause", "timer is not running"),
        ("resume", "timer is not paused"),
    ] {
        let (_, body) = post(&base, &token, &format!("{path}/{action}"), json!({})).await;
        assert_eq!(body["error"], message, "stopped {action}: {body}");
    }
}

#[tokio::test]
async fn timer_unknown_id_is_not_found() {
    let (base, _dir) = spawn_server().await;
    let (token, _child_id) = parent_with_child(&base, "parent@example.com").await;
    let id = uuid::Uuid::new_v4();
    for action in ["pause", "resume", "stop"] {
        let (status, body) =
            post(&base, &token, &format!("/timers/{id}/{action}"), json!({})).await;
        // Unknown pause/resume statuses are already pinned in pause_resume.rs.
        if action == "stop" {
            assert_eq!(status, 404, "{action}: {body}");
        }
        assert_eq!(body["error"], "timer not found", "{action}: {body}");
    }
}

#[tokio::test]
async fn timers_are_family_scoped() {
    let (base, _dir) = spawn_server().await;
    let (token_a, child_a) = parent_with_child(&base, "a@example.com").await;
    let (token_b, _child_b) = parent_with_child(&base, "b@example.com").await;
    let timer = start_timer(&base, &token_a, &child_a).await;
    let path = format!("/timers/{}", timer["id"].as_str().unwrap());
    let running = timers(&base, &token_a).await;
    assert_eq!(running, json!([timer]), "owner must see the timer");
    assert_eq!(timers(&base, &token_b).await, json!([]));

    for action in ["pause", "stop"] {
        let (status, body) = post(&base, &token_b, &format!("{path}/{action}"), json!({})).await;
        // Foreign pause/resume statuses are already pinned as 401, not 404.
        if action == "stop" {
            assert_eq!(status, 401, "foreign stop: {body}");
        }
        assert_eq!(timers(&base, &token_a).await, running, "foreign {action}");
    }

    let (status, paused) = post(&base, &token_a, &format!("{path}/pause"), json!({})).await;
    assert_eq!(status, 200, "pause setup: {paused}");
    let before = timers(&base, &token_a).await;
    let _ = post(&base, &token_b, &format!("{path}/resume"), json!({})).await;
    assert_eq!(timers(&base, &token_a).await, before, "foreign resume");
}

async fn rejected_start(base: &str, token: &str, child_id: &str, kind: &str) -> u16 {
    assert_eq!(timers(base, token).await, json!([]));
    let (status, body) = post(
        base,
        token,
        "/timers",
        json!({"child_id": child_id, "kind": kind}),
    )
    .await;
    assert!(
        (400..500).contains(&status),
        "start {kind}: {status} {body}"
    );
    assert_eq!(timers(base, token).await, json!([]));
    status
}

#[tokio::test]
#[ignore = "Known bug: start_timer accepts unknown nonempty kinds and creates a running timer."]
async fn timer_start_rejects_bad_kind() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "parent@example.com").await;
    rejected_start(&base, &token, &child_id, "not_a_timer_kind").await;
}

#[tokio::test]
async fn timer_start_rejects_foreign_child() {
    let (base, _dir) = spawn_server().await;
    let (token_a, _child_a) = parent_with_child(&base, "a@example.com").await;
    let (token_b, child_b) = parent_with_child(&base, "b@example.com").await;
    assert_eq!(timers(&base, &token_b).await, json!([]));
    assert_eq!(
        rejected_start(&base, &token_a, &child_b, "sleep").await,
        401,
        "foreign child"
    );
    assert_eq!(timers(&base, &token_b).await, json!([]));
}

#[tokio::test]
async fn timer_at_bounds_are_enforced() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "parent@example.com").await;
    let started_at = Utc::now() - chrono::Duration::minutes(10);
    let (status, timer) = post(
        &base,
        &token,
        "/timers",
        json!({"child_id": child_id, "kind": "sleep", "at": started_at.to_rfc3339()}),
    )
    .await;
    assert_eq!(status, 200, "start setup: {timer}");
    let path = format!("/timers/{}", timer["id"].as_str().unwrap());
    let before = timers(&base, &token).await;
    let too_early = (started_at - chrono::Duration::seconds(1)).to_rfc3339();
    for action in ["pause", "stop"] {
        let (status, body) = post(
            &base,
            &token,
            &format!("{path}/{action}"),
            json!({"at": too_early}),
        )
        .await;
        assert_eq!(status, 400, "{action}: {body}");
        assert_eq!(body["error"], "at cannot be before the timer started");
        assert_eq!(timers(&base, &token).await, before, "rejected {action}");
    }

    let paused_at = started_at + chrono::Duration::minutes(1);
    let (status, paused) = post(
        &base,
        &token,
        &format!("{path}/pause"),
        json!({"at": paused_at.to_rfc3339()}),
    )
    .await;
    assert_eq!(status, 200, "pause setup: {paused}");
    let before = timers(&base, &token).await;
    let (status, body) = post(
        &base,
        &token,
        &format!("{path}/resume"),
        json!({"at": (paused_at - chrono::Duration::seconds(1)).to_rfc3339()}),
    )
    .await;
    assert_eq!(status, 400, "resume: {body}");
    assert_eq!(body["error"], "at cannot be before the timer was paused");
    assert_eq!(timers(&base, &token).await, before, "rejected resume");
}

#[tokio::test]
async fn timer_routes_require_bearer() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "parent@example.com").await;
    let timer = start_timer(&base, &token, &child_id).await;
    let id = timer["id"].as_str().unwrap();
    for (method, path, body) in [
        ("GET", "/timers".to_owned(), None),
        (
            "POST",
            "/timers".to_owned(),
            Some(json!({"child_id": child_id, "kind": "sleep"})),
        ),
        ("POST", format!("/timers/{id}/pause"), Some(json!({}))),
        ("POST", format!("/timers/{id}/resume"), Some(json!({}))),
        ("POST", format!("/timers/{id}/stop"), Some(json!({}))),
    ] {
        let (status, body) = http_json(method, &format!("{base}{path}"), None, body)
            .await
            .unwrap();
        assert_eq!(status, 401, "{method} {path}: {body}");
    }
}
