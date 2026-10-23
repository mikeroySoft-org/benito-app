//! Integration: passwordless device keys, family invites, members, caregiver expiry.
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
    let dir = std::env::temp_dir().join(format!("benito-devinv-{}", uuid::Uuid::new_v4()));
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

async fn me(base: &str, token: &str) -> Value {
    let (status, body) = http_json("GET", &format!("{base}/me"), Some(token), None)
        .await
        .unwrap();
    assert_eq!(status, 200, "{body}");
    body
}

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};

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

    fn sign(&self, device_id: &str, ts: i64) -> String {
        let msg = format!("benito-device-auth:v1:{device_id}:{ts}");
        let sig: Signature = self.key.sign(msg.as_bytes());
        STANDARD.encode(sig.to_der().as_bytes())
    }
}

async fn device_session(base: &str, device: &Device, device_id: &str, ts: i64) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/auth/device/session"),
        None,
        Some(json!({ "device_id": device_id, "timestamp": ts, "signature": device.sign(device_id, ts) })),
    )
    .await
    .unwrap()
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

#[tokio::test]
async fn device_signup_then_signed_session_and_replay_rejected() {
    let (base, _dir) = spawn_server().await;
    let device = Device::new();
    let (status, body) = http_json(
        "POST",
        &format!("{base}/auth/device/signup"),
        None,
        Some(json!({ "name": "Alex", "public_key": device.public_key(), "device_name": "Alex's iPhone" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    let device_id = body["device_id"].as_str().unwrap().to_string();
    assert!(body["user"]["email"]
        .as_str()
        .unwrap()
        .ends_with("@device.benito.invalid"));

    // Passwordless account can create a family with its session.
    let token = body["token"].as_str().unwrap();
    let (status, _) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(token),
        Some(json!({ "name": "Test Family", "child_name": "Baby" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200);

    let ts = Utc::now().timestamp();
    let (status, body) = device_session(&base, &device, &device_id, ts).await;
    assert_eq!(status, 200, "{body}");
    let fresh = body["token"].as_str().unwrap();
    assert_eq!(me(&base, fresh).await["role"], "parent");

    // Same timestamp again → replay rejected.
    let (status, _) = device_session(&base, &device, &device_id, ts).await;
    assert_eq!(status, 401);
    // Stale timestamp → rejected.
    let (status, _) = device_session(&base, &device, &device_id, ts - 3600).await;
    assert_eq!(status, 400);
    // Wrong key signing for this device id → rejected.
    let other = Device::new();
    let (status, _) = device_session(&base, &other, &device_id, ts + 1).await;
    assert_eq!(status, 401);
    // Password login can't work for a passwordless account.
    let email = me(&base, fresh).await["user"]["email"]
        .as_str()
        .unwrap()
        .to_string();
    let (status, _) = http_json(
        "POST",
        &format!("{base}/auth/login"),
        None,
        Some(json!({ "email": email, "password": "!passwordless" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 401);
}

#[tokio::test]
async fn existing_password_account_attaches_device_key_and_keeps_password_login() {
    let (base, _dir) = spawn_server().await;
    let (token, _family) = parent_with_family(&base, "parent@example.com", "Family").await;
    assert_eq!(me(&base, &token).await["has_device_key"], false);
    let device = Device::new();
    let (status, body) = http_json(
        "POST",
        &format!("{base}/devices"),
        Some(&token),
        Some(json!({ "public_key": device.public_key(), "device_name": "iPhone" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    let device_id = body["device_id"].as_str().unwrap().to_string();
    // Idempotent for the same key.
    let (_, again) = http_json(
        "POST",
        &format!("{base}/devices"),
        Some(&token),
        Some(json!({ "public_key": device.public_key() })),
    )
    .await
    .unwrap();
    assert_eq!(again["device_id"], device_id.as_str());
    assert_eq!(me(&base, &token).await["has_device_key"], true);

    let (status, body) = device_session(&base, &device, &device_id, Utc::now().timestamp()).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["user"]["email"], "parent@example.com");

    let (status, _) = http_json(
        "POST",
        &format!("{base}/auth/login"),
        None,
        Some(json!({ "email": "parent@example.com", "password": "password123" })),
    )
    .await
    .unwrap();
    assert_eq!(
        status, 200,
        "password login still works after adding a device key"
    );

    // Another account can't claim the same key.
    let other = register(&base, "Other", "other@example.com").await;
    let (status, _) = http_json(
        "POST",
        &format!("{base}/devices"),
        Some(&other),
        Some(json!({ "public_key": device.public_key() })),
    )
    .await
    .unwrap();
    assert_eq!(status, 409);
}

#[tokio::test]
async fn invite_redeem_is_single_use_and_lists_member() {
    let (base, _dir) = spawn_server().await;
    let (token, family) = parent_with_family(&base, "p@example.com", "Family").await;
    let (status, invite) = create_invite(&base, &token, json!({})).await;
    assert_eq!(status, 200, "{invite}");
    assert_eq!(invite["role"], "parent");
    assert!(invite["secret"].as_str().unwrap().len() >= 40);

    let (_, pending) = http_json(
        "GET",
        &format!("{base}/families/invites"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(pending.as_array().unwrap().len(), 1);
    assert!(pending[0].get("secret").is_none(), "secret never listed");

    // Wrong secret.
    let mut forged = invite.clone();
    forged["secret"] = json!("nope");
    let (status, _) = redeem(&base, None, &forged, "Sam", &Device::new()).await;
    assert_eq!(status, 404);

    let joiner = Device::new();
    let (status, body) = redeem(&base, None, &invite, "Sam", &joiner).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["family"]["id"], family["id"]);
    let joiner_token = body["token"].as_str().unwrap().to_string();
    let m = me(&base, &joiner_token).await;
    assert_eq!(m["family"]["id"], family["id"]);
    assert_eq!(m["children"].as_array().unwrap().len(), 1);

    // Single use.
    let (status, _) = redeem(&base, None, &invite, "Eve", &Device::new()).await;
    assert_eq!(status, 404);

    let (status, members) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200);
    let members = members.as_array().unwrap();
    assert_eq!(members.len(), 2);
    let sam = members.iter().find(|m| m["name"] == "Sam").unwrap();
    assert_eq!(sam["role"], "parent");
    assert!(sam["email"].is_null(), "synthetic email hidden");
    assert_eq!(sam["devices"][0]["name"], "Sam's iPhone");
    assert!(sam["last_seen_at"].is_string());
    assert!(members
        .iter()
        .any(|m| m["is_you"] == true && m["email"] == "p@example.com"));
}

#[tokio::test]
async fn existing_account_without_family_redeems_with_bearer() {
    let (base, _dir) = spawn_server().await;
    let (token, family) = parent_with_family(&base, "a@example.com", "Family").await;
    let (_, invite) = create_invite(&base, &token, json!({})).await;
    let partner = register(&base, "Partner", "b@example.com").await;
    let (status, body) = redeem(&base, Some(&partner), &invite, "ignored", &Device::new()).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["user"]["email"], "b@example.com");
    assert_eq!(me(&base, &partner).await["family"]["id"], family["id"]);

    // Someone already in a family can't redeem.
    let (_, invite2) = create_invite(&base, &token, json!({})).await;
    let (status, _) = redeem(&base, Some(&partner), &invite2, "x", &Device::new()).await;
    assert_eq!(status, 409);
}

#[tokio::test]
async fn revoke_member_ends_sessions_and_device_key() {
    let (base, _dir) = spawn_server().await;
    let (token, _family) = parent_with_family(&base, "a@example.com", "Family").await;
    let (_, invite) = create_invite(&base, &token, json!({ "role": "caregiver" })).await;
    let sitter = Device::new();
    let (_, joined) = redeem(&base, None, &invite, "Sitter", &sitter).await;
    let sitter_token = joined["token"].as_str().unwrap().to_string();
    let sitter_id = joined["user"]["id"].as_str().unwrap().to_string();
    let device_id = joined["device_id"].as_str().unwrap().to_string();
    assert_eq!(me(&base, &sitter_token).await["role"], "caregiver");

    // Caregivers can't manage sharing.
    let (status, _) = create_invite(&base, &sitter_token, json!({})).await;
    assert_eq!(status, 403);
    let (status, _) = http_json(
        "POST",
        &format!("{base}/families/invite/rotate"),
        Some(&sitter_token),
        Some(json!({})),
    )
    .await
    .unwrap();
    assert_eq!(status, 403, "rotate blocked for caregivers");
    let (status, _) = mint(&base, &sitter_token).await;
    assert_eq!(status, 403);

    let (status, _) = http_json(
        "DELETE",
        &format!("{base}/families/members/{sitter_id}"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200);
    let (status, _) = http_json("GET", &format!("{base}/me"), Some(&sitter_token), None)
        .await
        .unwrap();
    assert_eq!(status, 401);
    let (status, _) = device_session(&base, &sitter, &device_id, Utc::now().timestamp()).await;
    assert_eq!(status, 401);
}

#[tokio::test]
async fn caregiver_access_expires() {
    let (base, dir) = spawn_server().await;
    let (token, _family) = parent_with_family(&base, "a@example.com", "Family").await;
    let (status, invite) = create_invite(
        &base,
        &token,
        json!({ "role": "caregiver", "access_hours": 4 }),
    )
    .await;
    assert_eq!(status, 200, "{invite}");
    assert_eq!(invite["access_hours"], 4);
    let (_, joined) = redeem(&base, None, &invite, "Sitter", &Device::new()).await;
    let sitter_token = joined["token"].as_str().unwrap().to_string();
    let expires: DateTime<Utc> = joined["access_expires_at"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!(expires > Utc::now() + chrono::Duration::hours(3));
    assert_eq!(me(&base, &sitter_token).await["role"], "caregiver");

    // Fast-forward: end the access window directly in the DB.
    let conn = rusqlite::Connection::open(dir.join("test.db")).unwrap();
    conn.execute(
        "UPDATE family_members SET expires_at = ?1 WHERE role = 'caregiver'",
        [(Utc::now() - chrono::Duration::minutes(1)).to_rfc3339()],
    )
    .unwrap();
    let (status, _) = http_json("GET", &format!("{base}/me"), Some(&sitter_token), None)
        .await
        .unwrap();
    assert_eq!(status, 401);
    let (_, members) = http_json(
        "GET",
        &format!("{base}/families/members"),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(members.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn expired_and_revoked_invites_fail() {
    let (base, dir) = spawn_server().await;
    let (token, _family) = parent_with_family(&base, "a@example.com", "Family").await;
    let (_, invite) = create_invite(&base, &token, json!({})).await;
    let (status, _) = http_json(
        "DELETE",
        &format!("{base}/families/invites/{}", invite["id"].as_str().unwrap()),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200);
    let (status, _) = redeem(&base, None, &invite, "X", &Device::new()).await;
    assert_eq!(status, 404);

    let (_, invite2) = create_invite(&base, &token, json!({ "expires_in_hours": 1 })).await;
    let conn = rusqlite::Connection::open(dir.join("test.db")).unwrap();
    conn.execute(
        "UPDATE family_invites SET expires_at = ?1 WHERE id = ?2",
        rusqlite::params![
            (Utc::now() - chrono::Duration::minutes(1)).to_rfc3339(),
            invite2["id"].as_str().unwrap()
        ],
    )
    .unwrap();
    let (status, _) = redeem(&base, None, &invite2, "X", &Device::new()).await;
    assert_eq!(status, 404);

    let (status, _) = create_invite(&base, &token, json!({ "expires_in_hours": 10000 })).await;
    assert_eq!(status, 400);
    let (status, _) = create_invite(&base, &token, json!({ "role": "admin" })).await;
    assert_eq!(status, 400);
}

#[tokio::test]
async fn server_info_is_public() {
    let (base, _dir) = spawn_server().await;
    let (status, body) = http_json("GET", &format!("{base}/server/info"), None, None)
        .await
        .unwrap();
    assert_eq!(status, 200);
    assert_eq!(body["service"], "benito-server");
    assert_eq!(body["server_id"].as_str().unwrap().len(), 36);
}
