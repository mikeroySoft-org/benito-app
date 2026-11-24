use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-family-setup-{}", uuid::Uuid::new_v4()));
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

async fn register(base: &str, email: &str) -> String {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({"name": "Parent", "email": email, "password": "password123"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "register: {body}");
    body["token"].as_str().unwrap().to_owned()
}

async fn create_family(base: &str, token: &str) -> Value {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(token),
        Some(json!({"name": "Family", "child_name": "Sam"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "create family: {body}");
    body
}

async fn children(base: &str, token: &str) -> Value {
    let (status, body) = http_json("GET", &format!("{base}/children"), Some(token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "list children: {body}");
    assert!(body.is_array(), "{body}");
    body
}

async fn join(base: &str, token: &str, code: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(token),
        Some(json!({"invite_code": code})),
    )
    .await
    .unwrap()
}

fn assert_error(status: u16, body: &Value, expected: u16, message: &str) {
    assert_eq!(status, expected, "{body}");
    assert!(body["error"].as_str().unwrap().contains(message), "{body}");
}

#[tokio::test]
async fn child_name_is_required_and_trimmed() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "parent@example.com").await;
    create_family(&base, &token).await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/children"),
        Some(&token),
        Some(json!({"name": "   "})),
    )
    .await
    .unwrap();
    assert_error(status, &body, 400, "name required");
    let (status, child) = http_json(
        "POST",
        &format!("{base}/children"),
        Some(&token),
        Some(json!({"name": " Ben "})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{child}");
    assert_eq!(child["name"], "Ben");
    assert!(child["id"].is_string(), "{child}");
    let listed = children(&base, &token).await;
    assert!(listed.as_array().unwrap().contains(&child), "{listed}");
    assert_eq!(listed.as_array().unwrap().len(), 2, "{listed}");
}

#[tokio::test]
async fn child_requires_family() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "parent@example.com").await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/children"),
        Some(&token),
        Some(json!({"name": "Ben"})),
    )
    .await
    .unwrap();
    assert_error(status, &body, 400, "join or create a family first");
    assert_eq!(children(&base, &token).await, json!([]));
}

#[tokio::test]
async fn children_are_family_scoped() {
    let (base, _dir) = spawn_server().await;
    let first = register(&base, "first@example.com").await;
    let first_family = create_family(&base, &first).await;
    let second = register(&base, "second@example.com").await;
    let second_family = create_family(&base, &second).await;
    assert_ne!(first_family["family"]["id"], second_family["family"]["id"]);
    assert_eq!(
        children(&base, &first).await,
        json!([first_family["child"]])
    );
    assert_eq!(
        children(&base, &second).await,
        json!([second_family["child"]])
    );
}

#[tokio::test]
async fn join_is_case_and_space_insensitive_and_single_family() {
    let (base, _dir) = spawn_server().await;
    let owner = register(&base, "owner@example.com").await;
    let family = create_family(&base, &owner).await;
    let member = register(&base, "member@example.com").await;
    let code = family["family"]["invite_code"].as_str().unwrap();
    let (status, joined) = join(&base, &member, &format!("  {}  ", code.to_lowercase())).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["id"], family["family"]["id"]);
    assert_eq!(children(&base, &member).await, json!([family["child"]]));
    let (status, body) = join(&base, &member, code).await;
    assert_error(status, &body, 409, "already in a family");
}

#[tokio::test]
async fn join_unknown_code_is_not_found() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "parent@example.com").await;
    let (status, body) = join(&base, &token, "UNKNOWN-CODE").await;
    assert_error(status, &body, 404, "invalid invite code");
    let (status, me) = http_json("GET", &format!("{base}/me"), Some(&token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{me}");
    assert!(me["family"].is_null(), "{me}");
    create_family(&base, &token).await;
}

#[tokio::test]
async fn rotate_invalidates_old_code() {
    let (base, _dir) = spawn_server().await;
    let owner = register(&base, "owner@example.com").await;
    let family = create_family(&base, &owner).await;
    let old_code = family["family"]["invite_code"].as_str().unwrap();
    let (status, rotated) = http_json(
        "POST",
        &format!("{base}/families/invite/rotate"),
        Some(&owner),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{rotated}");
    assert_eq!(rotated["id"], family["family"]["id"]);
    let new_code = rotated["invite_code"].as_str().unwrap();
    assert!(!new_code.is_empty());
    assert_ne!(new_code, old_code);
    let member = register(&base, "member@example.com").await;
    let (status, body) = join(&base, &member, old_code).await;
    assert_error(status, &body, 404, "invalid invite code");
    let (status, joined) = join(&base, &member, new_code).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["id"], family["family"]["id"]);
    assert_eq!(children(&base, &member).await, json!([family["child"]]));
}

#[tokio::test]
async fn family_routes_require_bearer() {
    let (base, _dir) = spawn_server().await;
    for (path, body) in [
        ("/children", json!({"name": "Ben"})),
        ("/families/join", json!({"invite_code": "UNKNOWN-CODE"})),
    ] {
        let (status, response) = http_json("POST", &format!("{base}{path}"), None, Some(body))
            .await
            .unwrap();
        assert_eq!(status, 401, "{path}: {response}");
    }
}
