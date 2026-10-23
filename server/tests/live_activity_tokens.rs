//! Live Activity token register/delete + timer.stop still works with APNs disabled.
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    // Ensure APNs stays disabled for this process.
    for k in ["APNS_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC"] {
        std::env::remove_var(k);
    }
    let dir = std::env::temp_dir().join(format!("benito-la-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let db_path = dir.join("test.db");
    let state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    assert!(!state.apns.is_enabled());
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
    extra_headers: &[(&str, &str)],
) -> Result<(u16, Value), BoxError> {
    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let mut builder = Request::builder().method(method).uri(url);
    builder = builder.header("content-type", "application/json");
    if let Some(t) = token {
        builder = builder.header("authorization", format!("Bearer {t}"));
    }
    for (k, v) in extra_headers {
        builder = builder.header(*k, *v);
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
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "register: {body}");
    body["token"].as_str().unwrap().to_string()
}

#[tokio::test]
async fn register_and_delete_live_activity_token() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "Ada", "ada-la@example.com").await;
    let (status, fam) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Baby" })),
        &[("x-client-id", "device-a")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam}");

    let push_tok = "ab".repeat(32); // 64 hex chars
    let (status, body) = http_json(
        "POST",
        &format!("{base}/live-activity/tokens"),
        Some(&token),
        Some(json!({
            "token": push_tok,
            "apns_env": "sandbox",
            "activity_id": "act-1"
        })),
        &[("x-client-id", "device-a")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["ok"], true);
    assert_eq!(body["apns_env"], "sandbox");
    assert_eq!(body["apns_enabled"], false);

    // Rotate token for same client — still one row.
    let push_tok2 = "cd".repeat(32);
    let (status, body) = http_json(
        "POST",
        &format!("{base}/live-activity/tokens"),
        Some(&token),
        Some(json!({ "token": push_tok2, "apns_env": "development" })),
        &[("x-client-id", "device-a")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["apns_env"], "sandbox");

    let (status, body) = http_json(
        "DELETE",
        &format!("{base}/live-activity/tokens"),
        Some(&token),
        None,
        &[("x-client-id", "device-a")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["deleted"], 1);
}

#[tokio::test]
async fn timer_stop_succeeds_with_apns_disabled() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "Bob", "bob-la@example.com").await;
    let (status, fam) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Baby" })),
        &[("x-client-id", "device-b")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam}");
    let child_id = fam["child"]["id"].as_str().unwrap();

    let push_tok = "ef".repeat(32);
    let (status, _) = http_json(
        "POST",
        &format!("{base}/live-activity/tokens"),
        Some(&token),
        Some(json!({ "token": push_tok, "apns_env": "sandbox" })),
        &[("x-client-id", "device-b")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200);

    let (status, timer) = http_json(
        "POST",
        &format!("{base}/timers"),
        Some(&token),
        Some(json!({ "child_id": child_id, "kind": "sleep" })),
        &[("x-client-id", "device-b")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{timer}");
    let timer_id = timer["id"].as_str().unwrap();

    let (status, stopped) = http_json(
        "POST",
        &format!("{base}/timers/{timer_id}/stop"),
        Some(&token),
        Some(json!({})),
        &[("x-client-id", "device-b")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{stopped}");
    assert_eq!(stopped["state"], "stopped");
}
