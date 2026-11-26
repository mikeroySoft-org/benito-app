//! Home glance and list read contracts; scratch servers only.
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-home-{}", uuid::Uuid::new_v4()));
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

async fn request(base: &str, token: &str, method: &str, path: &str, body: Option<Value>) -> Value {
    let (status, result) = http_json(method, &format!("{base}{path}"), Some(token), body)
        .await
        .unwrap();
    assert_eq!(status, 200, "{method} {path}: {result}");
    result
}

async fn event(base: &str, token: &str, child: &str, kind: &str, minute: i64) -> Value {
    let started = chrono::DateTime::parse_from_rfc3339("2020-01-01T00:00:00Z").unwrap()
        + chrono::Duration::minutes(minute);
    request(
        base,
        token,
        "POST",
        "/events",
        Some(json!({"child_id": child, "type": kind, "started_at": started.to_rfc3339()})),
    )
    .await
}

async fn delete(base: &str, token: &str, event: &Value) {
    request(
        base,
        token,
        "DELETE",
        &format!("/events/{}", event["id"].as_str().unwrap()),
        None,
    )
    .await;
}

async fn state(base: &str, token: &str, child: &str) -> Value {
    request(
        base,
        token,
        "GET",
        &format!("/state?child_id={child}"),
        None,
    )
    .await
}

async fn second_child(base: &str, token: &str) -> String {
    let child = request(
        base,
        token,
        "POST",
        "/children",
        Some(json!({"name": "Alex"})),
    )
    .await;
    child["id"].as_str().unwrap().to_owned()
}

fn ids(events: &Value) -> Vec<Value> {
    events
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].clone())
        .collect()
}

#[tokio::test]
async fn state_latest_picks_skip_deleted() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let empty = state(&base, &token, &child).await;
    assert_eq!(
        empty,
        json!({"child_id": child, "last_feed": null, "last_diaper": null,
        "last_medicine": null, "active_timer": null})
    );
    for (field, newest_kind, previous_kind, old_kind) in [
        ("last_feed", "feed_solid", "feed_bottle", "feed_breast"),
        ("last_diaper", "diaper", "diaper", "diaper"),
        ("last_medicine", "medicine", "medicine", "medicine"),
    ] {
        let newest = event(&base, &token, &child, newest_kind, 30).await;
        let previous = event(&base, &token, &child, previous_kind, 20).await;
        event(&base, &token, &child, old_kind, 10).await;
        assert_eq!(
            state(&base, &token, &child).await[field]["id"],
            newest["id"]
        );
        delete(&base, &token, &newest).await;
        assert_eq!(
            state(&base, &token, &child).await[field]["id"],
            previous["id"]
        );
    }
    let other_child = second_child(&base, &token).await;
    event(&base, &token, &other_child, "feed_solid", 40).await;
    assert!(state(&base, &token, &other_child).await["last_diaper"].is_null());
    assert_eq!(
        state(&base, &token, &child).await["last_feed"]["type"],
        "feed_bottle"
    );
}

#[tokio::test]
async fn state_active_timer_running_or_paused() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let timer = request(
        &base,
        &token,
        "POST",
        "/timers",
        Some(json!({"child_id": child, "kind": "sleep"})),
    )
    .await;
    let id = timer["id"].as_str().unwrap();
    let running = state(&base, &token, &child).await;
    assert_eq!(running["active_timer"]["id"], id);
    assert_eq!(running["active_timer"]["state"], "running");
    request(
        &base,
        &token,
        "POST",
        &format!("/timers/{id}/pause"),
        Some(json!({})),
    )
    .await;
    let paused = state(&base, &token, &child).await;
    assert_eq!(paused["active_timer"]["id"], id);
    assert_eq!(paused["active_timer"]["state"], "paused");
    request(
        &base,
        &token,
        "POST",
        &format!("/timers/{id}/stop"),
        Some(json!({})),
    )
    .await;
    assert!(state(&base, &token, &child).await["active_timer"].is_null());
}

#[tokio::test]
async fn state_access_rules() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let (_, foreign) = parent_with_child(&base, "b@example.com").await;
    for (path, auth, expected) in [
        (
            format!("/state?child_id={foreign}"),
            Some(token.as_str()),
            401,
        ),
        (format!("/state?child_id={child}"), None, 401),
        ("/state".to_owned(), Some(token.as_str()), 400),
        ("/state?child_id=bad".to_owned(), Some(token.as_str()), 400),
    ] {
        let (status, body) = http_json("GET", &format!("{base}{path}"), auth, None)
            .await
            .unwrap();
        assert_eq!(status, expected, "{path}: {body}");
    }
}

#[tokio::test]
async fn timeline_order_and_family_scope() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let sibling = second_child(&base, &token).await;
    let (other, foreign) = parent_with_child(&base, "b@example.com").await;
    let newest = event(&base, &token, &child, "diaper", 30).await;
    let sibling_event = event(&base, &token, &sibling, "note", 20).await;
    let oldest = event(&base, &token, &child, "medicine", 10).await;
    let deleted = event(&base, &token, &child, "note", 40).await;
    delete(&base, &token, &deleted).await;
    let foreign_event = event(&base, &other, &foreign, "note", 50).await;
    for route in ["/timeline", "/events"] {
        let scoped = request(
            &base,
            &token,
            "GET",
            &format!("{route}?child_id={child}"),
            None,
        )
        .await;
        assert_eq!(
            ids(&scoped),
            vec![newest["id"].clone(), oldest["id"].clone()]
        );
        let family = request(&base, &token, "GET", route, None).await;
        assert_eq!(
            ids(&family),
            vec![
                newest["id"].clone(),
                sibling_event["id"].clone(),
                oldest["id"].clone()
            ]
        );
        assert!(family
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e["deleted_at"].is_null()));
        let other_family = request(&base, &other, "GET", route, None).await;
        assert_eq!(ids(&other_family), vec![foreign_event["id"].clone()]);
    }
}

#[tokio::test]
async fn timeline_limit_clamp() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let mut created = Vec::new();
    for minute in 0..501 {
        created.push(event(&base, &token, &child, "note", minute).await["id"].clone());
    }
    created.reverse();
    for route in ["/timeline", "/events"] {
        for scope in [String::new(), format!("child_id={child}&")] {
            for (limit, count) in [("limit=0", 1), ("limit=1000", 500), ("", 100)] {
                let result = request(
                    &base,
                    &token,
                    "GET",
                    &format!("{route}?{scope}{limit}"),
                    None,
                )
                .await;
                assert_eq!(ids(&result), created[..count], "{route}?{scope}{limit}");
            }
        }
    }
}

#[tokio::test]
async fn timeline_since_includes_tombstones() {
    // catch_up.rs covers child-scoped deltas. Pin family-wide multi-child tombstones here.
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let sibling = second_child(&base, &token).await;
    let (other, foreign) = parent_with_child(&base, "b@example.com").await;
    let deleted = event(&base, &token, &child, "note", 30).await;
    tokio::time::sleep(Duration::from_millis(5)).await;
    let live = event(&base, &token, &sibling, "note", 10).await;
    tokio::time::sleep(Duration::from_millis(5)).await;
    delete(&base, &token, &deleted).await;
    event(&base, &other, &foreign, "note", 20).await;
    for route in ["/timeline", "/events"] {
        let changes = request(
            &base,
            &token,
            "GET",
            &format!("{route}?since=2020-01-01T00%3A00%3A00Z"),
            None,
        )
        .await;
        assert_eq!(
            ids(&changes),
            vec![live["id"].clone(), deleted["id"].clone()]
        );
        let rows = changes.as_array().unwrap();
        let first =
            chrono::DateTime::parse_from_rfc3339(rows[0]["updated_at"].as_str().unwrap()).unwrap();
        let last =
            chrono::DateTime::parse_from_rfc3339(rows[1]["updated_at"].as_str().unwrap()).unwrap();
        assert!(first < last);
        assert!(rows[0]["deleted_at"].is_null());
        assert!(rows[1]["deleted_at"].is_string());
    }
    // The /events invalid-cursor contract is already covered in catch_up.rs.
    let (status, body) = http_json(
        "GET",
        &format!("{base}/timeline?since=yesterday"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 400, "{body}");
}

#[tokio::test]
async fn timeline_requires_access() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let (_, foreign) = parent_with_child(&base, "b@example.com").await;
    for route in ["/timeline", "/events"] {
        for suffix in ["", "&since=2020-01-01T00%3A00%3A00Z"] {
            let path = format!("{base}{route}?child_id={foreign}{suffix}");
            let (status, body) = http_json("GET", &path, Some(&token), None).await.unwrap();
            assert_eq!(status, 401, "{path}: {body}");
        }
        for query in [String::new(), format!("?child_id={child}")] {
            let path = format!("{base}{route}{query}");
            let (status, body) = http_json("GET", &path, None, None).await.unwrap();
            assert_eq!(status, 401, "{path}: {body}");
        }
    }
}
