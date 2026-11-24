use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-auth-validation-{}", uuid::Uuid::new_v4()));
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

async fn register(base: &str) -> String {
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({"name": "Ada", "email": " ada@example.com ", "password": "password123"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "register: {body}");
    assert_eq!(body["user"]["email"], "ada@example.com");
    let token = body["token"].as_str().unwrap();
    assert!(!token.is_empty());
    token.to_owned()
}

#[tokio::test]
async fn register_rejects_short_password_and_blank_email() {
    let (base, _dir) = spawn_server().await;
    for (email, password, error) in [
        ("ada@example.com", "1234567", "password min 8 chars"),
        ("", "12345678", "email required"),
        ("   ", "12345678", "email required"),
    ] {
        let (status, body) = http_json(
            "POST",
            &format!("{base}/auth/register"),
            None,
            Some(json!({"name": "Ada", "email": email, "password": password})),
        )
        .await
        .unwrap();
        assert_eq!(status, 400, "register {email:?}: {body}");
        assert!(body["error"].as_str().unwrap().contains(error), "{body}");
    }
    register(&base).await;
}

#[tokio::test]
async fn register_conflict_is_case_insensitive() {
    let (base, _dir) = spawn_server().await;
    register(&base).await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/register"),
        None,
        Some(json!({"name": "Grace", "email": "Ada@Example.com", "password": "password456"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 409, "{body}");
    assert!(body["error"]
        .as_str()
        .unwrap()
        .contains("email already registered"));
}

#[tokio::test]
async fn login_trims_and_lowercases_email() {
    let (base, _dir) = spawn_server().await;
    register(&base).await;
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/login"),
        None,
        Some(json!({"email": " Ada@Example.com ", "password": "password123"})),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["user"]["email"], "ada@example.com");
    assert!(!body["token"].as_str().unwrap().is_empty());
}

#[tokio::test]
async fn login_failures_are_unauthorized() {
    let (base, _dir) = spawn_server().await;
    register(&base).await;
    for (email, password) in [
        ("ada@example.com", "wrongpassword"),
        ("nobody@example.com", "password123"),
        ("ada@example.com", "1234567"),
    ] {
        let (status, body) = http_json(
            "POST",
            &format!("{base}/auth/login"),
            None,
            Some(json!({"email": email, "password": password})),
        )
        .await
        .unwrap();
        assert_eq!(status, 401, "login {email}: {body}");
        assert_eq!(body["error"], "unauthorized");
    }
}

#[tokio::test]
async fn me_requires_bearer_token() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base).await;
    let (status, body) = http_json("GET", &format!("{base}/me"), Some(&token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "valid bearer: {body}");

    let (status, body) = http_json("GET", &format!("{base}/me"), None, None)
        .await
        .unwrap();
    assert_eq!(status, 401, "no authorization: {body}");

    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let request = Request::builder()
        .method("GET")
        .uri(format!("{base}/me"))
        .header("authorization", format!("Token {token}"))
        .body(Full::new(Bytes::new()))
        .unwrap();
    let response = client.request(request).await.unwrap();
    assert_eq!(response.status().as_u16(), 401);
}
