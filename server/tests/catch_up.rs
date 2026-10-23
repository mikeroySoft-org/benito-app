//! Integration: `since=` change feed on `GET /events` / `GET /timeline` used for client catch-up.
use std::time::Duration;

use bytes::Bytes;
use chrono::{DateTime, SecondsFormat, Utc};
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-catchup-{}", uuid::Uuid::new_v4()));
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

/// Creates three events with distinct `updated_at`; returns their ids in creation order.
async fn create_three_events(base: &str, token: &str, child_id: &str) -> Vec<String> {
    let mut ids = Vec::new();
    for subtype in ["wet", "dirty", "mixed"] {
        let (status, res) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(token),
            Some(json!({ "child_id": child_id, "type": "diaper", "subtype": subtype })),
        )
        .await
        .unwrap();
        assert_eq!(status, 200, "create {subtype}: {res}");
        ids.push(res["id"].as_str().unwrap().to_string());
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    ids
}

/// Percent-encodes the RFC3339 characters that are not safe as-is in a query value
/// (`+` would otherwise decode to a space).
fn enc(ts: &str) -> String {
    ts.replace('+', "%2B").replace(':', "%3A")
}

async fn changes(base: &str, token: &str, path_and_query: &str) -> (u16, Value) {
    http_json("GET", &format!("{base}{path_and_query}"), Some(token), None)
        .await
        .unwrap()
}

fn ids_of(events: &Value) -> Vec<String> {
    events
        .as_array()
        .unwrap_or_else(|| panic!("expected array, got {events}"))
        .iter()
        .map(|e| e["id"].as_str().unwrap().to_string())
        .collect()
}

fn updated_at(event: &Value) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(event["updated_at"].as_str().unwrap())
        .unwrap()
        .with_timezone(&Utc)
}

fn max_updated_at(events: &Value) -> DateTime<Utc> {
    events
        .as_array()
        .unwrap()
        .iter()
        .map(updated_at)
        .max()
        .unwrap()
}

fn assert_ascending(events: &Value) {
    let stamps: Vec<DateTime<Utc>> = events.as_array().unwrap().iter().map(updated_at).collect();
    assert!(
        stamps.windows(2).all(|w| w[0] <= w[1]),
        "updated_at not ascending: {events}"
    );
}

#[tokio::test]
async fn since_returns_changes_ascending_with_tombstones() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let before = (Utc::now() - chrono::Duration::seconds(1)).to_rfc3339();
    let ids = create_three_events(&base, &token, &child_id).await;

    let (status, first) = changes(
        &base,
        &token,
        &format!("/events?child_id={child_id}&since={}", enc(&before)),
    )
    .await;
    assert_eq!(status, 200, "{first}");
    assert_eq!(ids_of(&first), ids, "all three, oldest change first");
    assert_ascending(&first);

    // Paging: limit applies to the ascending feed, so the oldest changes come first.
    let (status, page) = changes(
        &base,
        &token,
        &format!("/events?child_id={child_id}&since={}&limit=2", enc(&before)),
    )
    .await;
    assert_eq!(status, 200, "{page}");
    assert_eq!(ids_of(&page), ids[..2].to_vec());

    let cursor = max_updated_at(&first).to_rfc3339_opts(SecondsFormat::AutoSi, true);

    let (status, patched) = http_json(
        "PATCH",
        &format!("{base}/events/{}", ids[0]),
        Some(&token),
        Some(json!({ "notes": "updated" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{patched}");
    tokio::time::sleep(Duration::from_millis(5)).await;
    let (status, deleted) = http_json(
        "DELETE",
        &format!("{base}/events/{}", ids[1]),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{deleted}");

    let (status, delta) = changes(
        &base,
        &token,
        &format!("/events?child_id={child_id}&since={}", enc(&cursor)),
    )
    .await;
    assert_eq!(status, 200, "{delta}");
    assert_eq!(
        ids_of(&delta),
        vec![ids[0].clone(), ids[1].clone()],
        "{delta}"
    );
    assert_ascending(&delta);
    let delta = delta.as_array().unwrap();
    assert_eq!(delta[0]["notes"], "updated");
    assert!(delta[0]["deleted_at"].is_null(), "{}", delta[0]);
    assert!(
        delta[1]["deleted_at"].is_string(),
        "tombstone must carry deleted_at: {}",
        delta[1]
    );

    // `GET /timeline` serves the same feed.
    let (status, timeline_delta) = changes(
        &base,
        &token,
        &format!("/timeline?child_id={child_id}&since={}", enc(&cursor)),
    )
    .await;
    assert_eq!(status, 200, "{timeline_delta}");
    assert_eq!(
        ids_of(&timeline_delta),
        vec![ids[0].clone(), ids[1].clone()]
    );

    // Without `since`, the regular listing still hides soft-deleted events.
    let (status, listing) = changes(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{listing}");
    let listed = ids_of(&listing);
    assert_eq!(listed.len(), 2, "{listing}");
    assert!(!listed.contains(&ids[1]), "deleted event leaked: {listing}");
    assert!(listing
        .as_array()
        .unwrap()
        .iter()
        .all(|e| e["deleted_at"].is_null()));
}

#[tokio::test]
async fn since_accepts_z_and_offset_forms_with_fractional_seconds() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    let ids = create_three_events(&base, &token, &child_id).await;

    let (status, all) = changes(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{all}");
    let first = all
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["id"] == ids[0].as_str())
        .unwrap();
    let cursor = updated_at(first);
    let z_form = cursor.to_rfc3339_opts(SecondsFormat::Nanos, true);
    let offset_form = cursor.to_rfc3339_opts(SecondsFormat::Nanos, false);
    assert!(z_form.ends_with('Z') && z_form.contains('.'), "{z_form}");
    assert!(offset_form.ends_with("+00:00"), "{offset_form}");

    let mut results = Vec::new();
    for since in [&z_form, &offset_form] {
        let (status, body) = changes(
            &base,
            &token,
            &format!("/events?child_id={child_id}&since={}", enc(since)),
        )
        .await;
        assert_eq!(status, 200, "since={since}: {body}");
        results.push(ids_of(&body));
    }
    assert_eq!(
        results[0],
        ids[1..].to_vec(),
        "strictly after the cursor event"
    );
    assert_eq!(
        results[0], results[1],
        "Z and +00:00 forms must be equivalent"
    );
}

#[tokio::test]
async fn invalid_since_is_bad_request() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "a@example.com").await;
    for bad in ["yesterday", "2026-09-26", "2026-09-26T01%3A00%3A00"] {
        let (status, body) = changes(
            &base,
            &token,
            &format!("/events?child_id={child_id}&since={bad}"),
        )
        .await;
        assert_eq!(status, 400, "since={bad}: {body}");
    }
}

#[tokio::test]
async fn since_is_family_scoped() {
    let (base, _dir) = spawn_server().await;
    let (token_a, child_a) = parent_with_child(&base, "a@example.com").await;
    let (token_b, _child_b) = parent_with_child(&base, "b@example.com").await;
    let before = enc(&(Utc::now() - chrono::Duration::seconds(1)).to_rfc3339());
    let ids = create_three_events(&base, &token_a, &child_a).await;

    let (status, body) = changes(
        &base,
        &token_b,
        &format!("/events?child_id={child_a}&since={before}"),
    )
    .await;
    assert_eq!(status, 401, "other family must not read this child: {body}");

    // No child_id: each user only sees changes for their own family's children.
    let (status, own) = changes(&base, &token_a, &format!("/timeline?since={before}")).await;
    assert_eq!(status, 200, "{own}");
    assert_eq!(ids_of(&own), ids);
    let (status, other) = changes(&base, &token_b, &format!("/timeline?since={before}")).await;
    assert_eq!(status, 200, "{other}");
    assert!(ids_of(&other).is_empty(), "cross-family leak: {other}");
}
