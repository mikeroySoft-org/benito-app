//! CSV export contract: formatting, visibility, authentication, and ordering.
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::{HeaderMap, Request};
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-export-csv-{}", uuid::Uuid::new_v4()));
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

async fn csv(base: &str, token: Option<&str>) -> (u16, HeaderMap, String) {
    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let mut request = Request::builder().uri(format!("{base}/export.csv"));
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = client
        .request(request.body(Full::new(Bytes::new())).unwrap())
        .await
        .unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    (status, headers, String::from_utf8(body.to_vec()).unwrap())
}

async fn event(base: &str, token: &str, child: &str, notes: &str, started: &str) -> String {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(token),
        Some(
            json!({"child_id": child, "type": "feed_bottle", "notes": notes,
                    "started_at": started, "amount_value": 3, "amount_unit": "oz"}),
        ),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    body["id"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn csv_headers_and_escaped_notes() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "escaping@example.com").await;
    let id = event(
        &base,
        &token,
        &child,
        "Fed 3 oz, then \"burped\"\nslept",
        "2026-11-01T10:00:00Z",
    )
    .await;
    let (status, headers, body) = csv(&base, Some(&token)).await;
    assert_eq!(status, 200);
    assert_eq!(headers["content-type"], "text/csv; charset=utf-8");
    assert_eq!(
        headers["content-disposition"],
        "attachment; filename=\"benito-events.csv\""
    );
    assert_eq!(body.lines().next().unwrap(), "id,child_id,type,subtype,started_at,ended_at,amount_value,amount_unit,side,notes,created_by,created_at");
    assert!(body.contains(&format!("\n{id},{child},feed_bottle,")));
    assert!(body.contains(",\"Fed 3 oz, then \"\"burped\"\"\nslept\","));
}

#[tokio::test]
async fn csv_excludes_soft_deleted_events() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "deletes@example.com").await;
    let deleted = event(
        &base,
        &token,
        &child,
        "deleted-note",
        "2026-11-01T10:00:00Z",
    )
    .await;
    let kept = event(&base, &token, &child, "kept-note", "2026-11-01T11:00:00Z").await;
    let (status, body) = http_json(
        "DELETE",
        &format!("{base}/events/{deleted}"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    let (status, _, body) = csv(&base, Some(&token)).await;
    assert_eq!(status, 200);
    assert!(!body.contains(&deleted));
    assert!(!body.contains("deleted-note"));
    assert!(body.contains(&kept));
    assert!(body.contains("kept-note"));
}

#[tokio::test]
async fn csv_isolates_families() {
    let (base, _dir) = spawn_server().await;
    let (first, first_child) = parent_with_child(&base, "first@example.com").await;
    let (second, second_child) = parent_with_child(&base, "second@example.com").await;
    event(
        &base,
        &first,
        &first_child,
        "first-family-private",
        "2026-11-01T10:00:00Z",
    )
    .await;
    event(
        &base,
        &second,
        &second_child,
        "second-family-private",
        "2026-11-01T10:00:00Z",
    )
    .await;
    for (token, own_child, own_note, other_child, other_note) in [
        (
            &first,
            &first_child,
            "first-family-private",
            &second_child,
            "second-family-private",
        ),
        (
            &second,
            &second_child,
            "second-family-private",
            &first_child,
            "first-family-private",
        ),
    ] {
        let (status, _, body) = csv(&base, Some(token)).await;
        assert_eq!(status, 200);
        assert!(body.contains(own_child));
        assert!(body.contains(own_note));
        assert!(!body.contains(other_child));
        assert!(!body.contains(other_note));
    }
}

#[tokio::test]
async fn csv_requires_authentication() {
    let (base, _dir) = spawn_server().await;
    for token in [None, Some("bogus-token")] {
        let (status, _, _) = csv(&base, token).await;
        assert_eq!(status, 401);
    }
}

#[tokio::test]
async fn csv_orders_events_by_started_at_ascending() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "order@example.com").await;
    let later = event(&base, &token, &child, "later", "2026-11-02T10:00:00Z").await;
    let earlier = event(&base, &token, &child, "earlier", "2026-11-01T10:00:00Z").await;
    let (status, _, body) = csv(&base, Some(&token)).await;
    assert_eq!(status, 200);
    let ids: Vec<_> = body
        .lines()
        .skip(1)
        .map(|line| line.split(',').next().unwrap())
        .collect();
    assert_eq!(ids, [earlier.as_str(), later.as_str()]);
}
