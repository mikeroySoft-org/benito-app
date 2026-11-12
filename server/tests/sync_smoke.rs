//! Integration smoke: two parents, one family, WS receives event.upsert from HTTP create.
use std::time::Duration;

use bytes::Bytes;
use futures_util::{SinkExt, StreamExt};
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-sync-{}", uuid::Uuid::new_v4()));
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
async fn ws_receives_event_upsert_from_other_parent() {
    let (base, _dir) = spawn_server().await;
    let token_a = register(&base, "Ada", "ada@example.com").await;
    let token_b = register(&base, "Bob", "bob@example.com").await;

    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token_a),
        Some(json!({
            "name": "Garcia",
            "child_name": "Sam",
            "child_birthdate": "2026-09-01",
            "child_sex": "M"
        })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "create family: {fam_body}");
    let invite = fam_body["invite_code"].as_str().unwrap().to_string();
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();

    let (status, join_body) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&token_b),
        Some(json!({ "invite_code": invite })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "join: {join_body}");

    let ws_url = base.replacen("http", "ws", 1) + "/sync";
    let (mut ws, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .expect("ws connect");
    ws.send(Message::Text(
        json!({
            "type": "auth",
            "payload": { "token": token_b, "client_id": "bob-client" }
        })
        .to_string(),
    ))
    .await
    .unwrap();

    let hello = tokio::time::timeout(Duration::from_secs(5), ws.next())
        .await
        .expect("hello timeout")
        .expect("ws closed")
        .expect("ws err");
    let hello_txt = hello.to_text().unwrap();
    let hello_json: Value = serde_json::from_str(hello_txt).unwrap();
    assert_eq!(hello_json["type"], "hello", "got {hello_txt}");

    let (status, created) = http_json(
        "POST",
        &format!("{base}/events"),
        Some(&token_a),
        Some(json!({
            "child_id": child_id,
            "type": "diaper",
            "subtype": "wet",
            "notes": "smoke"
        })),
        &[("x-client-id", "ada-client")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "create event: {created}");
    let event_id = created["id"].as_str().unwrap().to_string();

    let mut saw_upsert = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = tokio::time::timeout(remaining, ws.next()).await;
        let Ok(Some(Ok(Message::Text(t)))) = msg else {
            continue;
        };
        let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
        if v["type"] == "event.upsert" {
            assert_eq!(v["payload"]["id"], event_id);
            assert_eq!(v["payload"]["type"], "diaper");
            assert_eq!(v["client_id"], "ada-client");
            saw_upsert = true;
            break;
        }
    }
    assert!(saw_upsert, "Bob did not receive event.upsert");
    let _ = ws.close(None).await;
}

#[tokio::test]
async fn feed_bottle_breast_sleep_timer_and_export() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "Parent", "p@example.com").await;
    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Sam" })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam_body}");
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();

    for (body, label) in [
        (
            json!({
                "child_id": child_id,
                "type": "feed_bottle",
                "amount_value": 3.5,
                "amount_unit": "oz",
                "subtype": "formula"
            }),
            "bottle",
        ),
        (
            json!({
                "child_id": child_id,
                "type": "feed_breast",
                "side": "L"
            }),
            "breast",
        ),
        (
            json!({
                "child_id": child_id,
                "type": "diaper",
                "subtype": "dirty"
            }),
            "diaper",
        ),
    ] {
        let (status, res) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(&token),
            Some(body),
            &[],
        )
        .await
        .unwrap();
        assert_eq!(status, 200, "{label}: {res}");
    }

    let (status, timer_body) = http_json(
        "POST",
        &format!("{base}/timers"),
        Some(&token),
        Some(json!({ "child_id": child_id, "kind": "sleep" })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{timer_body}");
    let timer_id = timer_body["id"].as_str().unwrap().to_string();

    tokio::time::sleep(Duration::from_millis(20)).await;

    let (status, stopped) = http_json(
        "POST",
        &format!("{base}/timers/{timer_id}/stop"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{stopped}");

    let (status, state_body) = http_json(
        "GET",
        &format!("{base}/state?child_id={child_id}"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{state_body}");
    assert!(state_body["last_feed"].is_object(), "{state_body}");
    assert!(state_body["last_diaper"].is_object(), "{state_body}");

    let (status, export_body) =
        http_json("GET", &format!("{base}/export"), Some(&token), None, &[])
            .await
            .unwrap();
    assert_eq!(status, 200, "{export_body}");
    assert!(export_body["family"].is_object());
    assert!(export_body["events"].as_array().unwrap().len() >= 4);
    assert!(!export_body["children"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn feed_breast_timer_creates_event_with_side() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "Parent", "breast@example.com").await;
    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Sam" })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam_body}");
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();

    let (status, timer_body) = http_json(
        "POST",
        &format!("{base}/timers"),
        Some(&token),
        Some(json!({ "child_id": child_id, "kind": "feed_breast", "side": "L" })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{timer_body}");
    assert_eq!(timer_body["side"], "L");
    let timer_id = timer_body["id"].as_str().unwrap().to_string();

    tokio::time::sleep(Duration::from_millis(20)).await;

    let (status, stopped) = http_json(
        "POST",
        &format!("{base}/timers/{timer_id}/stop"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{stopped}");

    let (status, state_body) = http_json(
        "GET",
        &format!("{base}/state?child_id={child_id}"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{state_body}");
    assert_eq!(state_body["last_feed"]["type"], "feed_breast");
    assert_eq!(state_body["last_feed"]["side"], "L");
    assert!(state_body["last_feed"]["ended_at"].is_string());
}

#[tokio::test]
async fn two_clients_ws_timer_and_event_fanout() {
    let (base, _dir) = spawn_server().await;
    let token_a = register(&base, "Ada", "ada2@example.com").await;
    let token_b = register(&base, "Bob", "bob2@example.com").await;

    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token_a),
        Some(json!({
            "name": "Garcia",
            "child_name": "Sam",
            "child_birthdate": "2026-09-01",
            "child_sex": "M"
        })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "create family: {fam_body}");
    let invite = fam_body["invite_code"].as_str().unwrap().to_string();
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();

    let (status, _) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&token_b),
        Some(json!({ "invite_code": invite })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200);

    let ws_url = base.replacen("http", "ws", 1) + "/sync";

    let (mut ws_a, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .expect("ws a");
    ws_a.send(Message::Text(
        json!({
            "type": "auth",
            "payload": { "token": token_a, "client_id": "ada-phone" }
        })
        .to_string(),
    ))
    .await
    .unwrap();
    let (mut ws_b, _) = tokio_tungstenite::connect_async(&ws_url)
        .await
        .expect("ws b");
    ws_b.send(Message::Text(
        json!({
            "type": "auth",
            "payload": { "token": token_b, "client_id": "bob-phone" }
        })
        .to_string(),
    ))
    .await
    .unwrap();

    {
        let hello = tokio::time::timeout(Duration::from_secs(5), ws_a.next())
            .await
            .expect("hello timeout")
            .expect("ws closed")
            .expect("ws err");
        let v: Value = serde_json::from_str(hello.to_text().unwrap()).unwrap();
        assert_eq!(v["type"], "hello");
    }
    {
        let hello = tokio::time::timeout(Duration::from_secs(5), ws_b.next())
            .await
            .expect("hello timeout")
            .expect("ws closed")
            .expect("ws err");
        let v: Value = serde_json::from_str(hello.to_text().unwrap()).unwrap();
        assert_eq!(v["type"], "hello");
    }

    // A starts breast timer → B should see timer.upsert
    let (status, timer_body) = http_json(
        "POST",
        &format!("{base}/timers"),
        Some(&token_a),
        Some(json!({ "child_id": child_id, "kind": "feed_breast", "side": "R" })),
        &[("x-client-id", "ada-phone")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{timer_body}");
    let timer_id = timer_body["id"].as_str().unwrap().to_string();

    let mut saw_timer = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = tokio::time::timeout(remaining, ws_b.next()).await;
        let Ok(Some(Ok(Message::Text(t)))) = msg else {
            continue;
        };
        let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
        if v["type"] == "timer.upsert" {
            assert_eq!(v["payload"]["id"], timer_id);
            assert_eq!(v["payload"]["side"], "R");
            assert_eq!(v["client_id"], "ada-phone");
            saw_timer = true;
            break;
        }
    }
    assert!(saw_timer, "Bob did not receive timer.upsert");

    // B stops timer → A should see timer.stop (and feed event upsert)
    let (status, stopped) = http_json(
        "POST",
        &format!("{base}/timers/{timer_id}/stop"),
        Some(&token_b),
        None,
        &[("x-client-id", "bob-phone")],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{stopped}");

    let mut saw_stop = false;
    let mut saw_feed = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while tokio::time::Instant::now() < deadline && !(saw_stop && saw_feed) {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        let msg = tokio::time::timeout(remaining, ws_a.next()).await;
        let Ok(Some(Ok(Message::Text(t)))) = msg else {
            continue;
        };
        let v: Value = serde_json::from_str(&t).unwrap_or(Value::Null);
        if v["type"] == "timer.stop" && v["payload"]["id"] == timer_id {
            saw_stop = true;
        }
        if v["type"] == "event.upsert" && v["payload"]["type"] == "feed_breast" {
            assert_eq!(v["payload"]["side"], "R");
            saw_feed = true;
        }
    }
    assert!(saw_stop, "Ada did not receive timer.stop");
    assert!(saw_feed, "Ada did not receive feed_breast event.upsert");

    let _ = ws_a.close(None).await;
    let _ = ws_b.close(None).await;
}

#[tokio::test]
async fn daily_summary_and_invite_rotate() {
    let (base, _dir) = spawn_server().await;
    let token = register(&base, "Parent", "sum@example.com").await;
    let (status, fam_body) = http_json(
        "POST",
        &format!("{base}/families"),
        Some(&token),
        Some(json!({ "name": "F", "child_name": "Sam" })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{fam_body}");
    let child_id = fam_body["child"]["id"].as_str().unwrap().to_string();
    let old_invite = fam_body["invite_code"].as_str().unwrap().to_string();

    // Noon UTC keeps every fixture (incl. the sleep 2h→1h ago) inside the UTC `day` window,
    // whatever time the suite runs.
    let now = chrono::Utc::now()
        .date_naive()
        .and_hms_opt(12, 0, 0)
        .unwrap()
        .and_utc();
    let day = now.format("%Y-%m-%d").to_string();

    for body in [
        json!({
            "child_id": child_id,
            "type": "feed_bottle",
            "amount_value": 3.0,
            "amount_unit": "oz",
            "started_at": now.to_rfc3339()
        }),
        json!({
            "child_id": child_id,
            "type": "feed_breast",
            "side": "L",
            "started_at": now.to_rfc3339()
        }),
        json!({
            "child_id": child_id,
            "type": "diaper",
            "subtype": "wet",
            "started_at": now.to_rfc3339()
        }),
        json!({
            "child_id": child_id,
            "type": "diaper",
            "subtype": "dirty",
            "started_at": now.to_rfc3339()
        }),
        json!({
            "child_id": child_id,
            "type": "sleep",
            "started_at": (now - chrono::Duration::hours(2)).to_rfc3339(),
            "ended_at": (now - chrono::Duration::hours(1)).to_rfc3339()
        }),
    ] {
        let (status, res) = http_json(
            "POST",
            &format!("{base}/events"),
            Some(&token),
            Some(body),
            &[],
        )
        .await
        .unwrap();
        assert_eq!(status, 200, "{res}");
    }

    let (status, summary) = http_json(
        "GET",
        &format!("{base}/summary/daily?child_id={child_id}&day={day}"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{summary}");
    assert_eq!(summary["feed_bottle_count"], 1);
    assert_eq!(summary["bottle_oz_total"], 3.0);
    assert_eq!(summary["feed_breast_count"], 1);
    assert_eq!(summary["feed_breast_left"], 1);
    assert_eq!(summary["diaper_wet"], 1);
    assert_eq!(summary["diaper_dirty"], 1);
    assert_eq!(summary["sleep_event_count"], 1);
    assert!((summary["sleep_hours"].as_f64().unwrap() - 1.0).abs() < 0.01);

    let (status, csv_val) = http_json(
        "GET",
        &format!("{base}/export.csv"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{csv_val}");
    let csv = csv_val.as_str().unwrap_or("");
    // When body is not JSON, http_json wraps as String Value
    let csv_text = if csv.is_empty() {
        csv_val.to_string().trim_matches('"').replace("\\n", "\n")
    } else {
        csv.to_string()
    };
    assert!(csv_text.contains("feed_bottle"), "{csv_text}");
    assert!(csv_text.starts_with("id,child_id,type") || csv_text.contains("id,child_id,type"));

    let (status, rotated) = http_json(
        "POST",
        &format!("{base}/families/invite/rotate"),
        Some(&token),
        None,
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{rotated}");
    let new_invite = rotated["invite_code"].as_str().unwrap().to_string();
    assert_ne!(new_invite, old_invite);

    let token_outsider = register(&base, "Eve", "eve@example.com").await;
    let (status, join_fail) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&token_outsider),
        Some(json!({ "invite_code": old_invite })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 404, "old invite should be dead: {join_fail}");

    let (status, join_ok) = http_json(
        "POST",
        &format!("{base}/families/join"),
        Some(&token_outsider),
        Some(json!({ "invite_code": new_invite })),
        &[],
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{join_ok}");
}
