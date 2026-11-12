//! Integration: `activity` events with a subtype — walk / car-ride outings and crying —
//! logged directly or auto-created when a `walk` / `car_ride` / `crying` timer stops.
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
    let dir = std::env::temp_dir().join(format!("benito-activity-{}", uuid::Uuid::new_v4()));
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

async fn start_timer(
    base: &str,
    token: &str,
    child_id: &str,
    kind: &str,
    side: Option<&str>,
) -> Value {
    let mut body = json!({ "child_id": child_id, "kind": kind });
    if let Some(s) = side {
        body["side"] = json!(s);
    }
    let (status, timer) = http_json("POST", &format!("{base}/timers"), Some(token), Some(body))
        .await
        .unwrap();
    assert_eq!(status, 200, "start {kind}: {timer}");
    timer
}

/// `POST /timers/{id}/{action}` with an empty JSON body (as clients send).
async fn timer_action(base: &str, token: &str, id: &str, action: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{base}/timers/{id}/{action}"),
        Some(token),
        Some(json!({})),
    )
    .await
    .unwrap()
}

fn events_of_type(events: &Value, ty: &str) -> Vec<Value> {
    events
        .as_array()
        .unwrap_or_else(|| panic!("expected array, got {events}"))
        .iter()
        .filter(|e| e["type"] == ty)
        .cloned()
        .collect()
}

async fn post_event(base: &str, token: &str, body: Value) -> (u16, Value) {
    http_json("POST", &format!("{base}/events"), Some(token), Some(body))
        .await
        .unwrap()
}

#[tokio::test]
async fn walk_and_car_ride_timers_create_activity_events() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "walk@example.com").await;

    for kind in ["walk", "car_ride"] {
        let timer = start_timer(&base, &token, &child_id, kind, None).await;
        assert_eq!(timer["kind"], kind, "{timer}");
        let id = timer["id"].as_str().unwrap().to_string();
        let (status, stopped) = timer_action(&base, &token, &id, "stop").await;
        assert_eq!(status, 200, "{stopped}");
    }

    let (status, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{events}");
    let mut subtypes: Vec<String> = events_of_type(&events, "activity")
        .iter()
        .map(|e| {
            assert!(e["ended_at"].is_string(), "auto event is a span: {e}");
            assert!(e["side"].is_null(), "{e}");
            e["subtype"].as_str().unwrap().to_string()
        })
        .collect();
    subtypes.sort();
    assert_eq!(subtypes, vec!["car_ride", "walk"]);
    // Outings never masquerade as sleep or feeds.
    assert!(events_of_type(&events, "sleep").is_empty(), "{events}");
}

#[tokio::test]
async fn activity_event_requires_known_subtype() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "ride@example.com").await;
    let start = (Utc::now() - chrono::Duration::minutes(40)).to_rfc3339();
    let end = (Utc::now() - chrono::Duration::minutes(10)).to_rfc3339();

    let (status, ev) = post_event(
        &base,
        &token,
        json!({ "child_id": child_id, "type": "activity", "subtype": "car_ride",
                "started_at": start, "ended_at": end }),
    )
    .await;
    assert_eq!(status, 200, "{ev}");
    assert_eq!(ev["subtype"], "car_ride");

    let (status, body) = post_event(
        &base,
        &token,
        json!({ "child_id": child_id, "type": "activity", "started_at": start }),
    )
    .await;
    assert_eq!(status, 400, "missing subtype must fail: {body}");

    let (status, body) = post_event(
        &base,
        &token,
        json!({ "child_id": child_id, "type": "activity", "subtype": "jog", "started_at": start }),
    )
    .await;
    assert_eq!(status, 400, "unknown subtype must fail: {body}");

    // Edits keep the subtype valid too.
    let id = ev["id"].as_str().unwrap();
    let (status, body) = http_json(
        "PATCH",
        &format!("{base}/events/{id}"),
        Some(&token),
        Some(json!({ "subtype": "jog" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 400, "{body}");
    let (status, body) = http_json(
        "PATCH",
        &format!("{base}/events/{id}"),
        Some(&token),
        Some(json!({ "subtype": "walk" })),
    )
    .await
    .unwrap();
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["subtype"], "walk");
}

fn enc(ts: &str) -> String {
    ts.replace('+', "%2B").replace(':', "%3A")
}

/// Crying is an `activity` subtype: its timer stops into an event like walk / car ride.
#[tokio::test]
async fn crying_timer_creates_activity_event() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "cry@example.com").await;

    let timer = start_timer(&base, &token, &child_id, "crying", None).await;
    assert_eq!(timer["kind"], "crying", "{timer}");
    let id = timer["id"].as_str().unwrap().to_string();
    let (status, stopped) = timer_action(&base, &token, &id, "stop").await;
    assert_eq!(status, 200, "{stopped}");

    let (status, events) = get(&base, &token, &format!("/events?child_id={child_id}")).await;
    assert_eq!(status, 200, "{events}");
    let activities = events_of_type(&events, "activity");
    assert_eq!(activities.len(), 1, "{events}");
    assert_eq!(activities[0]["subtype"], "crying");
    assert!(activities[0]["ended_at"].is_string(), "{events}");
}

/// `crying_seconds` clips a spell across midnight, subtracts paused time, and ignores
/// other activity subtypes (walks).
#[tokio::test]
async fn summary_crying_seconds_clip_per_day_and_exclude_outings() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "crysum@example.com").await;

    let day0 = chrono::NaiveDate::from_ymd_opt(2026, 10, 5)
        .unwrap()
        .and_hms_opt(0, 0, 0)
        .unwrap()
        .and_utc();
    let day1 = day0 + chrono::Duration::days(1);
    let day2 = day0 + chrono::Duration::days(2);
    let at = |d: chrono::DateTime<Utc>, h: i64, m: i64| {
        (d + chrono::Duration::hours(h) + chrono::Duration::minutes(m)).to_rfc3339()
    };

    for body in [
        // 23:50 → 00:10: 10 min each side of midnight.
        json!({ "child_id": child_id, "type": "activity", "subtype": "crying",
                "started_at": at(day0, 23, 50), "ended_at": at(day1, 0, 10),
                "notes": "gassy" }),
        // 30 min wall clock with 10 min paused → 20 min on day0.
        json!({ "child_id": child_id, "type": "activity", "subtype": "crying",
                "started_at": at(day0, 9, 0), "ended_at": at(day0, 9, 30),
                "payload_json": { "paused_seconds": 600 } }),
        // A walk is an activity too but not crying.
        json!({ "child_id": child_id, "type": "activity", "subtype": "walk",
                "started_at": at(day0, 12, 0), "ended_at": at(day0, 13, 0) }),
    ] {
        let (status, ev) = post_event(&base, &token, body).await;
        assert_eq!(status, 200, "{ev}");
    }

    let summary = |from: chrono::DateTime<Utc>, to: chrono::DateTime<Utc>| {
        let (base, token, child_id) = (base.clone(), token.clone(), child_id.clone());
        async move {
            let (status, s) = get(
                &base,
                &token,
                &format!(
                    "/summary/daily?child_id={child_id}&from={}&to={}",
                    enc(&from.to_rfc3339()),
                    enc(&to.to_rfc3339())
                ),
            )
            .await;
            assert_eq!(status, 200, "{s}");
            s
        }
    };

    let s0 = summary(day0, day1).await;
    let c0 = s0["crying_seconds"].as_f64().unwrap();
    assert!(
        (c0 - 30.0 * 60.0).abs() < 1.0,
        "day0 crying ~30m, got {c0}: {s0}"
    );

    let s1 = summary(day1, day2).await;
    let c1 = s1["crying_seconds"].as_f64().unwrap();
    assert!(
        (c1 - 10.0 * 60.0).abs() < 1.0,
        "day1 crying ~10m, got {c1}: {s1}"
    );
}

/// Regression for the "12h 12m nursing" report (Oct 23, 2026): live row 91f2e5ef is a
/// Sep 27 `feed_breast` log with no `ended_at`. The summary treated it as nursing from then
/// until now, so every later day got midnight → now added. Events without an end add no
/// time to nursing, sleep, or crying; finished ones still clip to the window.
#[tokio::test]
async fn summary_durations_ignore_events_without_end() {
    let (base, _dir) = spawn_server().await;
    let (token, child_id) = parent_with_child(&base, "noend@example.com").await;

    let mut bodies = vec![
        // The orphan, plus open sleep and crying logs of the same shape.
        json!({ "child_id": child_id, "type": "feed_breast", "side": "L",
                "started_at": "2026-09-27T11:02:17.191389+00:00" }),
        json!({ "child_id": child_id, "type": "sleep",
                "started_at": "2026-10-20T10:00:00+00:00" }),
        json!({ "child_id": child_id, "type": "activity", "subtype": "crying",
                "started_at": "2026-10-20T11:00:00+00:00" }),
        // A finished sleep inside the day: 07:54:58 → 11:31:41 UTC = 13_003 s.
        json!({ "child_id": child_id, "type": "sleep",
                "started_at": "2026-10-23T07:54:58+00:00", "ended_at": "2026-10-23T11:31:41+00:00" }),
    ];
    // Oct 23 PDT's real nursing sessions: 799 + 931 + 110 + 1113 = 2953 s.
    for (side, start, end) in [
        (
            "R",
            "2026-10-23T07:33:03+00:00",
            "2026-10-23T07:46:22+00:00",
        ),
        (
            "L",
            "2026-10-23T11:31:50+00:00",
            "2026-10-23T11:47:21+00:00",
        ),
        (
            "L",
            "2026-10-23T12:55:22+00:00",
            "2026-10-23T12:57:12+00:00",
        ),
        (
            "L",
            "2026-10-23T12:59:22+00:00",
            "2026-10-23T13:17:55+00:00",
        ),
    ] {
        bodies.push(
            json!({ "child_id": child_id, "type": "feed_breast", "side": side,
                            "started_at": start, "ended_at": end }),
        );
    }
    for body in bodies {
        let (status, ev) = post_event(&base, &token, body).await;
        assert_eq!(status, 200, "{ev}");
    }

    // Oct 23 in Pacific time, as the app sends it.
    let (status, s) = get(
        &base,
        &token,
        &format!(
            "/summary/daily?child_id={child_id}&from={}&to={}",
            enc("2026-10-23T00:00:00-07:00"),
            enc("2026-10-24T00:00:00-07:00")
        ),
    )
    .await;
    assert_eq!(status, 200, "{s}");
    let nursing = s["nursing_seconds"].as_f64().unwrap();
    assert!(
        (nursing - 2953.0).abs() < 1.0,
        "nursing ~49m, got {nursing}: {s}"
    );
    let sleep = s["sleep_hours"].as_f64().unwrap();
    assert!(
        (sleep - 13_003.0 / 3600.0).abs() < 0.01,
        "sleep ~3.61h, got {sleep}: {s}"
    );
    assert_eq!(s["crying_seconds"].as_f64().unwrap(), 0.0, "{s}");
}
