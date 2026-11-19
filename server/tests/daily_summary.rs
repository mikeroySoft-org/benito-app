//! Daily summary authentication, isolation, window and bottle conversion contracts.
use std::time::Duration;

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use serde_json::{json, Value};

type BoxError = Box<dyn std::error::Error + Send + Sync>;

async fn spawn_server() -> (String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("benito-daily-summary-{}", uuid::Uuid::new_v4()));
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

fn enc(ts: &str) -> String {
    ts.replace('+', "%2B").replace(':', "%3A")
}

fn window(child: &str, from: &str, to: &str) -> String {
    format!(
        "/summary/daily?child_id={child}&from={}&to={}",
        enc(from),
        enc(to)
    )
}

async fn post_event(base: &str, token: &str, body: Value) -> Value {
    let (status, event) = http_json("POST", &format!("{base}/events"), Some(token), Some(body))
        .await
        .unwrap();
    assert_eq!(status, 200, "{event}");
    event
}

#[tokio::test]
async fn summary_requires_auth() {
    let (base, _dir) = spawn_server().await;
    let (_token, child) = parent_with_child(&base, "auth@example.com").await;
    let url = format!("{base}/summary/daily?child_id={child}&day=2026-11-19");
    for token in [None, Some("bogus-token")] {
        let (status, body) = http_json("GET", &url, token, None).await.unwrap();
        assert_eq!(status, 401, "{body}");
    }
}

#[tokio::test]
async fn summary_is_family_scoped() {
    let (base, _dir) = spawn_server().await;
    let (first, child) = parent_with_child(&base, "first@example.com").await;
    let (second, other_child) = parent_with_child(&base, "second@example.com").await;
    post_event(
        &base,
        &first,
        json!({"child_id": child, "type": "diaper",
        "subtype": "wet", "started_at": "2026-11-19T12:00:00Z"}),
    )
    .await;
    let path = format!("/summary/daily?child_id={child}&day=2026-11-19");
    let (status, before) = get(&base, &first, &path).await;
    assert_eq!(status, 200, "{before}");
    assert_eq!(before["diaper_wet"], 1);
    assert_eq!(before["total_events"], 1);
    post_event(
        &base,
        &second,
        json!({"child_id": other_child, "type": "diaper",
        "subtype": "wet", "started_at": "2026-11-19T12:00:00Z"}),
    )
    .await;
    let (status, denied) = get(&base, &second, &path).await;
    assert_eq!(status, 404, "{denied}");
    let (status, after) = get(&base, &first, &path).await;
    assert_eq!(status, 200, "{after}");
    assert_eq!(after, before);
}

#[tokio::test]
async fn summary_omits_soft_deleted_events() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "delete@example.com").await;
    let diaper = post_event(
        &base,
        &token,
        json!({"child_id": child, "type": "diaper",
        "subtype": "wet", "started_at": "2026-11-19T12:00:00Z"}),
    )
    .await;
    let bottle = post_event(
        &base,
        &token,
        json!({"child_id": child, "type": "feed_bottle",
        "amount_value": 3, "amount_unit": "oz", "started_at": "2026-11-19T13:00:00Z"}),
    )
    .await;
    let path = window(
        &child,
        "2026-11-19T00:00:00+00:00",
        "2026-11-20T00:00:00+00:00",
    );
    let (status, before) = get(&base, &token, &path).await;
    assert_eq!(status, 200, "{before}");
    assert_eq!(before["total_events"], 2);
    assert_eq!(before["feed_bottle_count"], 1);
    assert_eq!(before["bottle_oz_total"], 3.0);
    let (status, body) = http_json(
        "DELETE",
        &format!("{base}/events/{}", bottle["id"].as_str().unwrap()),
        Some(&token),
        None,
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    let (status, after) = get(&base, &token, &path).await;
    assert_eq!(status, 200, "{after}");
    assert_eq!(after["diaper_wet"], 1);
    assert_eq!(after["feed_bottle_count"], 0);
    assert_eq!(after["bottle_oz_total"], 0.0);
    assert_eq!(after["total_events"], 1);
    let (status, events) = get(&base, &token, &format!("/events?child_id={child}")).await;
    assert_eq!(status, 200, "{events}");
    assert!(events
        .as_array()
        .unwrap()
        .iter()
        .any(|event| event["id"] == diaper["id"]));
}

#[tokio::test]
async fn summary_rejects_invalid_windows() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "windows@example.com").await;
    for to in ["2026-11-19T00:00:00+00:00", "2026-11-18T00:00:00+00:00"] {
        let (status, body) = get(
            &base,
            &token,
            &window(&child, "2026-11-19T00:00:00+00:00", to),
        )
        .await;
        assert_eq!(status, 400, "{body}");
        assert!(
            body["error"]
                .as_str()
                .unwrap()
                .contains("to must be after from"),
            "{body}"
        );
    }
    for day in ["19-11-2026", "yesterday"] {
        let (status, body) = get(
            &base,
            &token,
            &format!("/summary/daily?child_id={child}&day={day}"),
        )
        .await;
        assert_eq!(status, 400, "{body}");
        assert!(
            body["error"]
                .as_str()
                .unwrap()
                .contains("day must be YYYY-MM-DD"),
            "{body}"
        );
    }
}

async fn midnight_events(base: &str, token: &str, child: &str) {
    for (at, subtype) in [
        ("2026-11-19T00:00:00Z", "wet"),
        ("2026-11-20T00:00:00Z", "dirty"),
    ] {
        post_event(
            base,
            token,
            json!({"child_id": child, "type": "diaper",
            "subtype": subtype, "started_at": at}),
        )
        .await;
    }
}

#[tokio::test]
async fn summary_day_param_is_utc_calendar_day() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "utc@example.com").await;
    midnight_events(&base, &token, &child).await;
    let (status, body) = get(
        &base,
        &token,
        &format!("/summary/daily?child_id={child}&day=2026-11-19"),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["from"], "2026-11-19T00:00:00Z");
    assert_eq!(body["to"], "2026-11-20T00:00:00Z");
    assert_eq!(body["day"], "2026-11-19");
    assert_eq!(body["diaper_wet"], 1);
    assert_eq!(body["diaper_dirty"], 0);
    assert_eq!(body["total_events"], 1);
}

#[tokio::test]
async fn summary_from_to_override_day() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "override@example.com").await;
    midnight_events(&base, &token, &child).await;
    let path = window(
        &child,
        "2026-11-20T00:00:00+00:00",
        "2026-11-21T00:00:00+00:00",
    );
    let (status, body) = get(&base, &token, &format!("{path}&day=2026-11-19")).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["from"], "2026-11-20T00:00:00Z");
    assert_eq!(body["to"], "2026-11-21T00:00:00Z");
    assert_eq!(body["day"], "2026-11-19");
    assert_eq!(body["diaper_wet"], 0);
    assert_eq!(body["diaper_dirty"], 1);
    assert_eq!(body["total_events"], 1);
}

#[tokio::test]
async fn summary_bottle_oz_equiv_converts_ml() {
    let (base, _dir) = spawn_server().await;
    let (token, child) = parent_with_child(&base, "bottles@example.com").await;
    for (amount, unit) in [(3.0, "oz"), (29.5735, "ml")] {
        post_event(
            &base,
            &token,
            json!({"child_id": child, "type": "feed_bottle",
            "amount_value": amount, "amount_unit": unit, "started_at": "2026-11-19T12:00:00Z"}),
        )
        .await;
    }
    let (status, body) = get(
        &base,
        &token,
        &window(
            &child,
            "2026-11-19T00:00:00+00:00",
            "2026-11-20T00:00:00+00:00",
        ),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["feed_bottle_count"], 2);
    assert_eq!(body["bottle_oz_total"], 3.0);
    assert_eq!(body["bottle_ml_total"], 29.57);
    assert_eq!(body["bottle_oz_equiv"], 4.0);
}
