//! JSON backup contract: complete family data, tombstones, membership, and authentication.
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
    let dir = std::env::temp_dir().join(format!("benito-export-json-{}", uuid::Uuid::new_v4()));
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

async fn post(base: &str, token: &str, path: &str, body: Value) -> Value {
    let (status, body) = http_json("POST", &format!("{base}{path}"), Some(token), Some(body))
        .await
        .unwrap();
    assert_eq!(status, 200, "{path}: {body}");
    body
}

async fn export(base: &str, token: &str) -> Value {
    let before = Utc::now();
    let (status, bundle) = http_json("GET", &format!("{base}/export"), Some(token), None)
        .await
        .unwrap();
    let after = Utc::now();
    assert_eq!(status, 200, "export: {bundle}");
    let exported_at = DateTime::parse_from_rfc3339(bundle["exported_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    assert!(exported_at >= before && exported_at <= after);
    bundle
}

struct FamilyData {
    token: String,
    family: Value,
    children: Vec<Value>,
    events: Vec<Value>,
    timers: Vec<Value>,
}

async fn family_data(base: &str, email: &str) -> FamilyData {
    let token = register(base, "Parent", email).await;
    let created = post(
        base,
        &token,
        "/families",
        json!({"name": email, "child_name": "Sam"}),
    )
    .await;
    let second = post(
        base,
        &token,
        "/children",
        json!({"name": "Pip", "birthdate": "2026-01-02", "sex": "female"}),
    )
    .await;
    let children = vec![created["child"].clone(), second];
    let mut events = Vec::new();
    for body in [
        json!({"child_id": children[0]["id"], "type": "feed_bottle",
            "started_at": "2026-01-03T10:00:00Z", "amount_value": 90,
            "amount_unit": "ml", "notes": "Breakfast"}),
        json!({"child_id": children[1]["id"], "type": "diaper", "subtype": "wet",
            "started_at": "2026-01-03T11:00:00Z", "notes": "Changed"}),
        json!({"child_id": children[0]["id"], "type": "sleep",
            "started_at": "2026-01-03T12:00:00Z", "ended_at": "2026-01-03T13:00:00Z",
            "payload_json": {"location": "crib"}}),
    ] {
        events.push(post(base, &token, "/events", body).await);
    }
    let timer = post(
        base,
        &token,
        "/timers",
        json!({"child_id": children[1]["id"], "kind": "sleep"}),
    )
    .await;
    FamilyData {
        token,
        family: created["family"].clone(),
        children,
        events,
        timers: vec![timer],
    }
}

fn assert_rows(actual: &Value, expected: &[Value]) {
    let mut actual = actual.as_array().unwrap().clone();
    let mut expected = expected.to_vec();
    actual.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    expected.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
    assert_eq!(actual, expected);
}

fn assert_family_data(bundle: &Value, data: &FamilyData) {
    assert_eq!(bundle["family"], data.family);
    assert_rows(&bundle["children"], &data.children);
    assert_rows(&bundle["events"], &data.events);
    assert_rows(&bundle["timers"], &data.timers);
}

#[tokio::test]
async fn export_contains_family_children_events_timers() {
    let (base, _dir) = spawn_server().await;
    let data = family_data(&base, "contents@example.com").await;
    let bundle = export(&base, &data.token).await;
    assert_family_data(&bundle, &data);
}

#[tokio::test]
async fn export_includes_tombstones() {
    let (base, _dir) = spawn_server().await;
    let mut data = family_data(&base, "deleted@example.com").await;
    let before = Utc::now();
    let (status, body) = http_json(
        "DELETE",
        &format!("{base}/events/{}", data.events[0]["id"].as_str().unwrap()),
        Some(&data.token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "delete: {body}");
    let bundle = export(&base, &data.token).await;
    let deleted = bundle["events"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == data.events[0]["id"])
        .expect("JSON backup must retain the deleted event");
    let deleted_at = DateTime::parse_from_rfc3339(deleted["deleted_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc);
    assert!(deleted_at >= before && deleted_at <= Utc::now());
    data.events[0]["deleted_at"] = deleted["deleted_at"].clone();
    data.events[0]["updated_at"] = deleted["updated_at"].clone();
    assert_family_data(&bundle, &data);
}

#[tokio::test]
async fn export_family_isolation() {
    let (base, _dir) = spawn_server().await;
    let first = family_data(&base, "first@example.com").await;
    let second = family_data(&base, "second@example.com").await;
    for data in [&first, &second] {
        assert_family_data(&export(&base, &data.token).await, data);
    }
}

#[tokio::test]
async fn export_caregiver_sees_same_bundle() {
    let (base, _dir) = spawn_server().await;
    let data = family_data(&base, "owner@example.com").await;
    let caregiver = register(&base, "Caregiver", "caregiver@example.com").await;
    post(
        &base,
        &caregiver,
        "/families/join",
        json!({"invite_code": data.family["invite_code"]}),
    )
    .await;
    let mut owner_bundle = export(&base, &data.token).await;
    let mut caregiver_bundle = export(&base, &caregiver).await;
    assert_family_data(&caregiver_bundle, &data);
    owner_bundle.as_object_mut().unwrap().remove("exported_at");
    caregiver_bundle
        .as_object_mut()
        .unwrap()
        .remove("exported_at");
    assert_eq!(caregiver_bundle, owner_bundle);
}

#[tokio::test]
async fn export_without_family_is_empty() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "New", "new@example.com").await;
    let mut bundle = export(&base, &token).await;
    bundle.as_object_mut().unwrap().remove("exported_at");
    assert_eq!(
        bundle,
        json!({"family": null, "children": [], "events": [], "timers": []})
    );
}

#[tokio::test]
async fn export_requires_auth() {
    let (base, _dir) = spawn_server().await;
    for token in [None, Some("bad-token")] {
        let (status, body) = http_json("GET", &format!("{base}/export"), token, None)
            .await
            .unwrap();
        assert_eq!(status, 401, "export: {body}");
    }
}
