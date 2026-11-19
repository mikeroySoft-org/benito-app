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
    let dir =
        std::env::temp_dir().join(format!("benito-event-validation-{}", uuid::Uuid::new_v4()));
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

#[tokio::test]
async fn unknown_event_type_is_rejected() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "parent@test.local").await;
    for ty in ["feed", "unknown", ""] {
        let (status, body) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(&token),
            Some(json!({"child_id": child, "type": ty})),
        )
        .await
        .unwrap();
        assert_eq!(status, 400, "{ty:?}: {body}");
        let error = body["error"].as_str().unwrap();
        assert!(error.contains(&format!("'{ty}'")), "{error}");
    }
}

#[tokio::test]
async fn allowlisted_event_types_can_be_created() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "parent@test.local").await;
    for ty in [
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
    ] {
        let (status, body) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(&token),
            Some(json!({"child_id": child, "type": ty, "started_at": "2026-01-01T12:00:00Z"})),
        )
        .await
        .unwrap();
        assert_eq!(status, 200, "{ty}: {body}");
        assert_eq!(body["type"], ty);
    }
}

#[tokio::test]
async fn create_event_is_family_scoped() {
    let (base, _dir) = spawn_server().await;
    let (owner, child) = parent_with_child(&base, "owner@test.local").await;
    let (other, _other_child) = parent_with_child(&base, "other@test.local").await;
    let url = format!("{base}/events?child_id={child}");
    let (status, before) = http_json("GET", &url, Some(&owner), None).await.unwrap();
    assert_eq!(status, 200, "{before}");
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&other),
        Some(json!({"child_id": child, "type": "note"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 401, "{body}");
    let (status, after) = http_json("GET", &url, Some(&owner), None).await.unwrap();
    assert_eq!(status, 200, "{after}");
    assert_eq!(after.as_array().unwrap(), before.as_array().unwrap());
}

#[tokio::test]
async fn create_event_requires_auth() {
    let (base, _dir) = spawn_server().await;
    let (_token, child) = parent_with_child(&base, "parent@test.local").await;
    for token in [None, Some("bogus-token")] {
        let (status, body) = http_json(
            "POST",
            &format!("{base}/events"),
            token,
            Some(json!({"child_id": child, "type": "note"})),
        )
        .await
        .unwrap();
        assert_eq!(status, 401, "{body}");
    }
}

#[tokio::test]
async fn create_rejects_ended_before_started() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "parent@test.local").await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&token),
        Some(json!({
            "child_id": child, "type": "sleep",
            "started_at": "2026-01-01T12:00:00Z",
            "ended_at": "2026-01-01T11:59:59Z"
        })),
    )
    .await
    .unwrap();
    assert_eq!(status, 400, "{body}");
    assert!(body["error"]
        .as_str()
        .unwrap()
        .contains("ended_at cannot be before started_at"));
}

#[tokio::test]
async fn create_started_at_follows_edit_slack() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "parent@test.local").await;
    for (minutes, expected) in [(6, 400), (2, 200)] {
        let started = Utc::now() + chrono::Duration::minutes(minutes);
        let (status, body) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(&token),
            Some(json!({"child_id": child, "type": "note", "started_at": started})),
        )
        .await
        .unwrap();
        assert_eq!(status, expected, "{minutes} minutes: {body}");
        if expected == 400 {
            assert!(body["error"]
                .as_str()
                .unwrap()
                .contains("started_at cannot be in the future"));
        }
    }
}

#[tokio::test]
async fn create_accepts_equal_start_and_end() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "parent@test.local").await;
    let started = "2026-01-01T12:00:00Z";
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&token),
        Some(
            json!({"child_id": child, "type": "sleep", "started_at": started, "ended_at": started}),
        ),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["started_at"], body["ended_at"]);
}
