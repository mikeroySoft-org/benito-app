//! Integration: `DELETE /me` (in-app account deletion).
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
    let dir = std::env::temp_dir().join(format!("benito-acctdel-{}", uuid::Uuid::new_v4()));
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

async fn get(base: &str, token: &str, path_and_query: &str) -> (u16, Value) {
    http_json("GET", &format!("{base}{path_and_query}"), Some(token), None)
        .await
        .unwrap()
}

async fn register_status(base: &str, name: &str, email: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({ "name": name, "email": email, "password": "password123" })),
    )
    .await
    .unwrap()
}

async fn register(base: &str, name: &str, email: &str) -> String {
    let (status, body) = register_status(base, name, email).await;
    assert_eq!(status, 200, "register: {body}");
    body["token"].as_str().unwrap().to_string()
}

async fn login(base: &str, email: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/auth/login"),
        None,
        Some(json!({ "email": email, "password": "password123" })),
    )
    .await
    .unwrap()
}

/// Creates a family for `token`; returns `(invite_code, child_id)`.
async fn create_family(base: &str, token: &str) -> (String, String) {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(token),
        Some(json!({ "name": "Family", "child_name": "Sam" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "create family: {body}");
    (
        body["family"]["invite_code"].as_str().unwrap().to_string(),
        body["child"]["id"].as_str().unwrap().to_string(),
    )
}

/// Logs a finished car ride; returns the event id.
async fn log_event(base: &str, token: &str, child_id: &str, minutes_ago: i64) -> String {
    let start = (Utc::now() - chrono::Duration::minutes(minutes_ago)).to_rfc3339();
    let end = (Utc::now() - chrono::Duration::minutes(minutes_ago - 5)).to_rfc3339();
    let (status, body) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(token),
        Some(
            json!({ "child_id": child_id, "type": "activity", "subtype": "car_ride",
                     "started_at": start, "ended_at": end }),
        ),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "log event: {body}");
    body["id"].as_str().unwrap().to_string()
}

async fn delete_account(base: &str, token: Option<&str>) -> (u16, Value) {
    http_json("DELETE", &format!("{base}/me"), token, None)
        .await
        .unwrap()
}

fn db_count(dir: &std::path::Path, sql: &str) -> i64 {
    let conn = rusqlite::Connection::open(dir.join("test.db")).unwrap();
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

#[tokio::test]
async fn sole_member_delete_removes_family_and_history() {
    let (base, dir) = spawn_server().await;
    let token = register(&base, "Solo", "solo@example.com").await;
    let (_, child_id) = create_family(&base, &token).await;
    log_event(&base, &token, &child_id, 60).await;
    log_event(&base, &token, &child_id, 30).await;

    let (status, body) = delete_account(&base, Some(&token)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body, json!({ "deleted": true }));

    let (status, body) = get(&base, &token, "/me").await;
    assert_eq!(status, 401, "{body}");
    for table in [
        "users",
        "families",
        "family_members",
        "children",
        "events",
        "sessions",
    ] {
        assert_eq!(
            db_count(&dir, &format!("SELECT COUNT(*) FROM {table}")),
            0,
            "{table} should be empty"
        );
    }
    let (status, body) = login(&base, "solo@example.com").await;
    assert_eq!(status, 401, "{body}");

    // The email is free again and the new account starts with nothing.
    let fresh = register(&base, "Solo", "solo@example.com").await;
    let (status, me) = get(&base, &fresh, "/me").await;
    assert_eq!(status, 200, "{me}");
    assert!(me["family"].is_null(), "{me}");
    assert_eq!(me["children"], json!([]), "{me}");
}

#[tokio::test]
async fn member_delete_keeps_family_and_shared_history() {
    let (base, dir) = spawn_server().await;
    let stay = register(&base, "Stay", "stay@example.com").await;
    let (invite_code, child_id) = create_family(&base, &stay).await;
    let go = register(&base, "Go", "go@example.com").await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&go),
        Some(json!({ "invite_code": invite_code })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "join: {body}");
    let (_, go_me) = get(&base, &go, "/me").await;
    let go_id = go_me["user"]["id"].as_str().unwrap().to_string();

    let mut expected = vec![
        log_event(&base, &stay, &child_id, 90).await,
        log_event(&base, &go, &child_id, 60).await,
        log_event(&base, &go, &child_id, 30).await,
    ];
    expected.sort();

    let (status, body) = delete_account(&base, Some(&go)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body, json!({ "deleted": true }));

    let (status, body) = get(&base, &go, "/me").await;
    assert_eq!(status, 401, "{body}");
    let (status, body) = login(&base, "go@example.com").await;
    assert_eq!(status, 401, "{body}");

    let (status, me) = get(&base, &stay, "/me").await;
    assert_eq!(status, 200, "{me}");
    assert_eq!(me["family"]["name"], "Family", "{me}");
    assert_eq!(me["children"][0]["id"], child_id.as_str(), "{me}");

    let (status, events) = get(&base, &stay, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{events}");
    let mut ids: Vec<String> = events
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap().to_string())
        .collect();
    ids.sort();
    assert_eq!(ids, expected, "{events}");

    let (status, members) = get(&base, &stay, "/families/members").await;
    assert_eq!(status, 200, "{members}");
    let members = members.as_array().unwrap();
    assert_eq!(members.len(), 1, "{members:?}");
    assert!(members.iter().all(|m| m["user_id"] != go_id.as_str()));

    // Their events still need a users row, but it no longer says who they were.
    assert_eq!(
        db_count(
            &dir,
            "SELECT COUNT(*) FROM users WHERE name = 'Former member'
             AND email LIKE '%@deleted.benito.invalid'"
        ),
        1
    );
    assert_eq!(
        db_count(
            &dir,
            "SELECT COUNT(*) FROM users WHERE email = 'go@example.com' OR name = 'Go'"
        ),
        0
    );
    let (status, body) = register_status(&base, "Go", "go@example.com").await;
    assert_eq!(status, 200, "email is free again: {body}");
}

#[tokio::test]
async fn only_parent_cannot_delete_while_caregivers_remain() {
    let (base, dir) = spawn_server().await;
    let parent = register(&base, "Parent", "parent@example.com").await;
    let (invite_code, child_id) = create_family(&base, &parent).await;
    let sitter = register(&base, "Sitter", "sitter@example.com").await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&sitter),
        Some(json!({ "invite_code": invite_code })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "join: {body}");
    // Invite codes make parents; caregivers come from device invites. Set the role directly.
    let (_, sitter_me) = get(&base, &sitter, "/me").await;
    let sitter_id = sitter_me["user"]["id"].as_str().unwrap().to_string();
    rusqlite::Connection::open(dir.join("test.db"))
        .unwrap()
        .execute(
            "UPDATE family_members SET role = 'caregiver' WHERE user_id = ?1",
            [&sitter_id],
        )
        .unwrap();
    log_event(&base, &parent, &child_id, 30).await;

    let (status, body) = delete_account(&base, Some(&parent)).await;
    assert_eq!(status, 409, "{body}");
    let (status, body) = get(&base, &parent, "/me").await;
    assert_eq!(status, 200, "refused delete changes nothing: {body}");
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM families"), 1);
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM family_members"), 2);
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM events"), 1);

    // The caregiver can go, and then the parent is the last member and can too.
    let (status, body) = delete_account(&base, Some(&sitter)).await;
    assert_eq!(status, 200, "{body}");
    let (status, body) = delete_account(&base, Some(&parent)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM families"), 0);
}

#[tokio::test]
async fn user_without_family_is_deleted() {
    let (base, dir) = spawn_server().await;
    let token = register(&base, "Alone", "alone@example.com").await;

    let (status, body) = delete_account(&base, Some(&token)).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body, json!({ "deleted": true }));

    let (status, body) = get(&base, &token, "/me").await;
    assert_eq!(status, 401, "{body}");
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM users"), 0);
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM sessions"), 0);
}

#[tokio::test]
async fn delete_requires_auth() {
    let (base, dir) = spawn_server().await;
    register(&base, "Keep", "keep@example.com").await;

    let (status, body) = delete_account(&base, None).await;
    assert_eq!(status, 401, "{body}");
    let (status, body) = delete_account(&base, Some("not-a-token")).await;
    assert_eq!(status, 401, "{body}");
    assert_eq!(db_count(&dir, "SELECT COUNT(*) FROM users"), 1);
}
