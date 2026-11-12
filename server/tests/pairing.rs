//! Integration: proximity partner pairing (`POST /families/pairing-tokens`, `POST /families/pair`).
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
    let dir = std::env::temp_dir().join(format!("benito-pairing-{}", uuid::Uuid::new_v4()));
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

/// Registers a parent and creates a family; returns `(token, family)`.
async fn parent_with_family(base: &str, email: &str, family_name: &str) -> (String, Value) {
    let token = register(base, "Parent", email).await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": family_name, "child_name": "Sam" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    (token, body["family"].clone())
}

async fn mint(base: &str, token: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/families/pairing-tokens"),
        Some(token),
        Some(json!({})),
    )
    .await
    .unwrap()
}

async fn pair(base: &str, token: &str, pairing_token: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/families/pair"),
        Some(token),
        Some(json!({ "token": pairing_token })),
    )
    .await
    .unwrap()
}

async fn me(base: &str, token: &str) -> Value {
    let (status, body) = http_json("GET", &format!("{base}/me"), Some(token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{body}");
    body
}

/// Direct DB handle for backdating timestamps (avoids long sleeps in tests).
fn open_db(dir: &std::path::Path) -> rusqlite::Connection {
    rusqlite::Connection::open(dir.join("test.db")).unwrap()
}

#[tokio::test]
async fn mint_and_redeem_joins_family_once() {
    let (base, _dir) = spawn_server().await;
    let (alice, family) = parent_with_family(&base, "alice@example.com", "Rossi").await;

    let before = Utc::now();
    let (status, minted) = mint(&base, &alice).await;
    assert_eq!(status, 200, "{minted}");
    assert_eq!(minted["family_name"], "Rossi", "{minted}");
    let pairing_token = minted["token"].as_str().unwrap().to_string();
    let expires_at: DateTime<Utc> =
        DateTime::parse_from_rfc3339(minted["expires_at"].as_str().unwrap())
            .unwrap()
            .with_timezone(&Utc);
    let ttl = expires_at - before;
    assert!(
        ttl > chrono::Duration::minutes(4)
            && ttl <= chrono::Duration::minutes(5) + chrono::Duration::seconds(5),
        "expires_at should be ~5 minutes out: {minted}"
    );

    let bob = register(&base, "Bob", "bob@example.com").await;
    let (status, joined) = pair(&base, &bob, &pairing_token).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["id"], family["id"], "{joined}");
    assert_eq!(joined["name"], "Rossi", "{joined}");
    assert_eq!(joined["invite_code"], family["invite_code"], "{joined}");
    let bob_me = me(&base, &bob).await;
    assert_eq!(bob_me["family"]["id"], family["id"], "{bob_me}");
    assert_eq!(bob_me["children"].as_array().unwrap().len(), 1, "{bob_me}");

    // Single use: a third user can't reuse it.
    let carol = register(&base, "Carol", "carol@example.com").await;
    let (status, body) = pair(&base, &carol, &pairing_token).await;
    assert_eq!(status, 404, "reused token: {body}");
    assert!(me(&base, &carol).await["family"].is_null());

    // Unknown token: same 404.
    let (status, body) = pair(&base, &carol, "not-a-real-token").await;
    assert_eq!(status, 404, "unknown token: {body}");
}

#[tokio::test]
async fn expired_token_is_rejected() {
    let (base, dir) = spawn_server().await;
    let (alice, _family) = parent_with_family(&base, "alice@example.com", "Rossi").await;
    let (status, minted) = mint(&base, &alice).await;
    assert_eq!(status, 200, "{minted}");
    let pairing_token = minted["token"].as_str().unwrap();

    open_db(&dir)
        .execute(
            "UPDATE pairing_tokens SET expires_at = ?2 WHERE token = ?1",
            rusqlite::params![
                pairing_token,
                (Utc::now() - chrono::Duration::seconds(1)).to_rfc3339()
            ],
        )
        .unwrap();

    let bob = register(&base, "Bob", "bob@example.com").await;
    let (status, body) = pair(&base, &bob, pairing_token).await;
    assert_eq!(status, 404, "expired token: {body}");
    assert!(me(&base, &bob).await["family"].is_null());
}

#[tokio::test]
async fn minting_requires_a_family() {
    let (base, _dir) = spawn_server().await;
    let loner = register(&base, "Loner", "loner@example.com").await;
    let (status, body) = mint(&base, &loner).await;
    assert_eq!(status, 404, "{body}");
}

#[tokio::test]
async fn member_of_a_family_cannot_redeem_and_does_not_burn_token() {
    let (base, _dir) = spawn_server().await;
    let (alice, family) = parent_with_family(&base, "alice@example.com", "Rossi").await;
    let (dave, other_family) = parent_with_family(&base, "dave@example.com", "Other").await;
    let (status, minted) = mint(&base, &alice).await;
    assert_eq!(status, 200, "{minted}");
    let pairing_token = minted["token"].as_str().unwrap();

    let (status, body) = pair(&base, &dave, pairing_token).await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(me(&base, &dave).await["family"]["id"], other_family["id"]);

    // Still redeemable by someone eligible.
    let bob = register(&base, "Bob", "bob@example.com").await;
    let (status, joined) = pair(&base, &bob, pairing_token).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["id"], family["id"], "{joined}");
}

#[tokio::test]
async fn leaving_a_family_allows_joining_another() {
    let (base, _dir) = spawn_server().await;
    let (alice, family) = parent_with_family(&base, "alice@example.com", "Rossi").await;
    let (dave, other_family) = parent_with_family(&base, "dave@example.com", "Other").await;

    let (status, body) = http_json("POST", &format!("{base}/families/leave"), Some(&dave), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{body}");
    assert!(me(&base, &dave).await["family"].is_null());
    // Leaving twice: nothing to leave.
    let (status, _) = http_json("POST", &format!("{base}/families/leave"), Some(&dave), None)
        .await
        .unwrap();
    assert_eq!(status, 404);

    let (_, minted) = mint(&base, &alice).await;
    let (status, joined) = pair(&base, &dave, minted["token"].as_str().unwrap()).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["id"], family["id"]);
    assert_ne!(joined["id"], other_family["id"]);
}

#[tokio::test]
async fn concurrent_redemptions_only_one_wins() {
    let (base, _dir) = spawn_server().await;
    let (alice, _family) = parent_with_family(&base, "alice@example.com", "Rossi").await;
    let (status, minted) = mint(&base, &alice).await;
    assert_eq!(status, 200, "{minted}");
    let pairing_token = minted["token"].as_str().unwrap();

    let bob = register(&base, "Bob", "bob@example.com").await;
    let carol = register(&base, "Carol", "carol@example.com").await;
    let ((s1, b1), (s2, b2)) = tokio::join!(
        pair(&base, &bob, pairing_token),
        pair(&base, &carol, pairing_token)
    );
    let mut statuses = [s1, s2];
    statuses.sort();
    assert_eq!(statuses, [200, 404], "bob: {b1}, carol: {b2}");
}
