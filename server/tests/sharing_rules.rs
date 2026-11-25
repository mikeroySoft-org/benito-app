//! Integration: sharing permissions, invite validation, and family isolation.
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-sharing-{}", uuid::Uuid::new_v4()));
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
        Some(json!({ "name": family_name, "child_name": "Baby" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    (token, body["family"].clone())
}

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use p256::ecdsa::SigningKey;

struct Device {
    key: SigningKey,
}

impl Device {
    fn new() -> Self {
        loop {
            let bytes: [u8; 32] = rand::random();
            if let Ok(key) = SigningKey::from_slice(&bytes) {
                return Self { key };
            }
        }
    }

    fn public_key(&self) -> String {
        STANDARD.encode(self.key.verifying_key().to_encoded_point(false).as_bytes())
    }
}

async fn create_invite(base: &str, token: &str, body: Value) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/families/invites"),
        Some(token),
        Some(body),
    )
    .await
    .unwrap()
}

async fn redeem(
    base: &str,
    token: Option<&str>,
    invite: &Value,
    name: &str,
    device: &Device,
) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/invites/redeem"),
        token,
        Some(json!({
            "invite_id": invite["id"],
            "secret": invite["secret"],
            "name": name,
            "public_key": device.public_key(),
            "device_name": format!("{name}'s iPhone"),
            "model": "iPhone17,1",
        })),
    )
    .await
    .unwrap()
}

fn assert_error(response: (u16, Value), status: u16, message: &str) {
    assert_eq!(response.0, status, "{}", response.1);
    assert!(
        response.1["error"].as_str().unwrap().contains(message),
        "{}",
        response.1
    );
}

#[tokio::test]
async fn caregiver_cannot_manage_sharing() {
    let (base, _dir) = spawn_server().await;
    let (parent, _) = parent_with_family(&base, "parent@example.com", "Family").await;
    let (status, invite) = create_invite(&base, &parent, json!({"role": "caregiver"})).await;
    assert_eq!(status, 200, "{invite}");
    let (status, joined) = redeem(&base, None, &invite, "Caregiver", &Device::new()).await;
    assert_eq!(status, 200, "{joined}");
    let caregiver = joined["token"].as_str().unwrap();
    let (status, pending) = create_invite(&base, &parent, json!({})).await;
    assert_eq!(status, 200, "{pending}");
    for (method, path, body) in [
        ("POST", "/families/invites".to_string(), Some(json!({}))),
        ("GET", "/families/invites".to_string(), None),
        (
            "DELETE",
            format!("/families/invites/{}", pending["id"].as_str().unwrap()),
            None,
        ),
        (
            "DELETE",
            format!(
                "/families/members/{}",
                joined["user"]["id"].as_str().unwrap()
            ),
            None,
        ),
    ] {
        assert_error(
            http_json(method, &format!("{base}{path}"), Some(caregiver), body)
                .await
                .unwrap(),
            403,
            "only parents can manage sharing",
        );
    }
    let (status, members) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(caregiver),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{members}");
    assert!(members
        .as_array()
        .unwrap()
        .iter()
        .any(|member| member["user_id"] == joined["user"]["id"]));
}

#[tokio::test]
async fn no_family_user_gets_not_found() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "No family", "alone@example.com").await;
    assert_error(
        create_invite(&base, &token, json!({})).await,
        404,
        "no family",
    );
    assert_error(
        http_json(
            "GET",
            &format!("{base}/families/members"),
            Some(&token),
            None,
        )
        .await
        .unwrap(),
        404,
        "no family",
    );
}

#[tokio::test]
async fn invite_input_is_validated() {
    let (base, _dir) = spawn_server().await;
    let (parent, _) = parent_with_family(&base, "parent@example.com", "Family").await;
    // Source caps: INVITE_MAX_HOURS = 24 * 7; ACCESS_MAX_HOURS = 24 * 365.
    const INVITE_MAX_HOURS: i64 = 168;
    const ACCESS_MAX_HOURS: i64 = 8760;
    for (body, message) in [
        (json!({"role": "admin"}), "role must be parent or caregiver"),
        (json!({"expires_in_hours": 0}), "expires_in_hours must be"),
        (
            json!({"expires_in_hours": INVITE_MAX_HOURS + 1}),
            "expires_in_hours must be",
        ),
        (
            json!({"role": "caregiver", "access_hours": 0}),
            "access_hours must be",
        ),
        (
            json!({"role": "caregiver", "access_hours": ACCESS_MAX_HOURS + 1}),
            "access_hours must be",
        ),
    ] {
        assert_error(create_invite(&base, &parent, body).await, 400, message);
    }
}

#[tokio::test]
async fn invite_terms_are_normalized() {
    let (base, _dir) = spawn_server().await;
    let (parent, _) = parent_with_family(&base, "parent@example.com", "Family").await;
    let (status, caregiver) = create_invite(
        &base,
        &parent,
        json!({"role": "Caregiver", "label": " \t\n "}),
    )
    .await;
    assert_eq!(status, 200, "{caregiver}");
    assert_eq!(caregiver["role"], "caregiver");
    assert!(caregiver["label"].is_null(), "{caregiver}");
    let (status, invite) = create_invite(
        &base,
        &parent,
        json!({"role": "parent", "access_hours": 24, "label": "x".repeat(100)}),
    )
    .await;
    assert_eq!(status, 200, "{invite}");
    assert!(invite["access_hours"].is_null(), "{invite}");
    assert_eq!(invite["label"], "x".repeat(60));
    let (status, pending) = http_json(
        "GET",
        &format!("{base}/families/invites"),
        Some(&parent),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{pending}");
    let stored = pending
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == caregiver["id"])
        .unwrap();
    assert_eq!(stored["role"], "caregiver");
}

#[tokio::test]
async fn remove_member_rules() {
    let (base, _dir) = spawn_server().await;
    let (parent, _) = parent_with_family(&base, "parent@example.com", "Family").await;
    let (other, _) = parent_with_family(&base, "other@example.com", "Other family").await;
    let (status, own) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(&parent),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{own}");
    let (status, before) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(&other),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{before}");
    for (target, status, message) in [
        (
            own[0]["user_id"].as_str().unwrap().to_string(),
            400,
            "use Leave family to remove yourself",
        ),
        (
            uuid::Uuid::new_v4().to_string(),
            404,
            "not a member of this family",
        ),
        (
            before[0]["user_id"].as_str().unwrap().to_string(),
            404,
            "not a member of this family",
        ),
    ] {
        assert_error(
            http_json(
                "DELETE",
                &format!("{base}/families/members/{target}"),
                Some(&parent),
                None,
            )
            .await
            .unwrap(),
            status,
            message,
        );
    }
    let (status, after) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(&other),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{after}");
    assert_eq!(after, before);
}

#[tokio::test]
async fn revoke_invite_rules() {
    let (base, _dir) = spawn_server().await;
    let (parent, _) = parent_with_family(&base, "parent@example.com", "Family").await;
    let (other, other_family) =
        parent_with_family(&base, "other@example.com", "Other family").await;
    let (status, invite) = create_invite(&base, &parent, json!({})).await;
    assert_eq!(status, 200, "{invite}");
    let path = format!("{base}/families/invites/{}", invite["id"].as_str().unwrap());
    let (status, revoked) = http_json("DELETE", &path, Some(&parent), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{revoked}");
    for path in [
        path,
        format!("{base}/families/invites/{}", uuid::Uuid::new_v4()),
    ] {
        assert_error(
            http_json("DELETE", &path, Some(&parent), None)
                .await
                .unwrap(),
            404,
            "no pending invite with that id",
        );
    }
    let (status, foreign) = create_invite(&base, &other, json!({})).await;
    assert_eq!(status, 200, "{foreign}");
    assert_error(
        http_json(
            "DELETE",
            &format!(
                "{base}/families/invites/{}",
                foreign["id"].as_str().unwrap()
            ),
            Some(&parent),
            None,
        )
        .await
        .unwrap(),
        404,
        "no pending invite with that id",
    );
    let (status, joined) = redeem(&base, None, &foreign, "Joiner", &Device::new()).await;
    assert_eq!(status, 200, "{joined}");
    assert_eq!(joined["family"]["id"], other_family["id"]);
}

#[tokio::test]
async fn sharing_routes_require_bearer() {
    let (base, _dir) = spawn_server().await;
    for (method, path, body) in [
        ("POST", "/families/invites", Some(json!({}))),
        ("GET", "/families/invites", None),
        (
            "DELETE",
            "/families/invites/00000000-0000-0000-0000-000000000001",
            None,
        ),
        ("GET", "/families/members", None),
        (
            "DELETE",
            "/families/members/00000000-0000-0000-0000-000000000001",
            None,
        ),
    ] {
        let (status, body) = http_json(method, &format!("{base}{path}"), None, body)
            .await
            .unwrap();
        assert_eq!(status, 401, "{method} {path}: {body}");
    }
}
