//! Integration: client-chosen event ids (`client_event_ids`), used when on-device history
//! moves to a server. Re-sending an id is a no-op; another family's id is a conflict.
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
    let dir = std::env::temp_dir().join(format!("benito-client-ids-{}", uuid::Uuid::new_v4()));
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

#[tokio::test]
async fn client_event_id_is_kept_and_idempotent() {
    let (base, dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "a@example.com").await;
    let id = uuid::Uuid::new_v4().to_string();
    let started = (Utc::now() - chrono::Duration::hours(2)).to_rfc3339();
    let body = json!({ "child_id": child, "type": "diaper", "subtype": "wet", "started_at": started, "id": id });

    let (status, first) = http_json("POST", &format!("{base}/events"), Some(&token), Some(body.clone())).await.unwrap();
    assert_eq!(status, 200, "{first}");
    assert_eq!(first["id"], json!(id));

    let mut retry = body.clone();
    retry["subtype"] = json!("dirty");
    let (status, second) = http_json("POST", &format!("{base}/events"), Some(&token), Some(retry)).await.unwrap();
    assert_eq!(status, 200, "{second}");
    assert_eq!(second["id"], json!(id));
    assert_eq!(second["subtype"], json!("wet"), "retry returns the stored event unchanged");

    let (status, list) = get(&base, &token, &format!("/events?child_id={child}")).await;
    assert_eq!(status, 200, "{list}");
    let count = list.as_array().unwrap().iter().filter(|e| e["id"] == json!(id)).count();
    assert_eq!(count, 1);

    // Without an id the server still mints one.
    let (status, minted) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&token),
        Some(json!({ "child_id": child, "type": "note", "notes": "hi" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{minted}");
    assert_ne!(minted["id"], json!(id));

    let (_, info) = get(&base, &token, "/server/info").await;
    assert!(info["features"].as_array().unwrap().contains(&json!("client_event_ids")), "{info}");
    let _ = std::fs::remove_dir_all(dir);
}

#[tokio::test]
async fn client_event_id_from_another_family_conflicts() {
    let (base, dir) = spawn_server().await;
    let (alice, alice_child) = parent_with_child(&base, "alice@example.com").await;
    let (bob, bob_child) = parent_with_child(&base, "bob@example.com").await;
    let id = uuid::Uuid::new_v4().to_string();
    let (status, _) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&alice),
        Some(json!({ "child_id": alice_child, "type": "diaper", "subtype": "wet", "notes": "private", "id": id })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200);
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&bob),
        Some(json!({ "child_id": bob_child, "type": "diaper", "subtype": "wet", "id": id })),
    )
    .await
    .unwrap();
    assert_eq!(status, 409, "{body}");
    assert!(!body.to_string().contains("private"), "never leaks the other family's event");
    let _ = std::fs::remove_dir_all(dir);
}
