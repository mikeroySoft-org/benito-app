//! Integration: the loopback admin API (token gate, status, people and devices, invites, backups).
use std::sync::Arc;
use std::time::Duration;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use benito_server::backup::BackupService;
use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::Request;
use hyper_util::client::legacy::Client;
use hyper_util::rt::TokioExecutor;
use p256::ecdsa::SigningKey;
use serde_json::{json, Value};

const ADMIN_TOKEN: &str = "admin-test-token";

struct Servers {
    public: String,
    admin: String,
    dir: std::path::PathBuf,
}

/// One state behind two listeners, as `benito-server` runs with `BENITO_ADMIN_ADDR` set.
async fn spawn_servers() -> Servers {
    let dir = std::env::temp_dir().join(format!("benito-admin-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let db_path = dir.join("test.db");
    let mut state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    state.backups = Some(Arc::new(BackupService::new(
        db_path,
        dir.join("backups"),
        3,
        0,
    )));

    let public = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let admin = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let servers = Servers {
        public: format!("http://{}", public.local_addr().unwrap()),
        admin: format!("http://{}", admin.local_addr().unwrap()),
        dir,
    };
    let admin_app = benito_server::admin::router(state.clone(), ADMIN_TOKEN);
    let public_app = benito_server::build_router(state);
    tokio::spawn(async move { axum::serve(public, public_app).await.unwrap() });
    tokio::spawn(async move { axum::serve(admin, admin_app).await.unwrap() });
    tokio::time::sleep(Duration::from_millis(50)).await;
    servers
}

async fn http_json(
    method: &str,
    url: &str,
    token: Option<&str>,
    body: Option<Value>,
) -> (u16, Value) {
    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let mut builder = Request::builder()
        .method(method)
        .uri(url)
        .header("content-type", "application/json");
    if let Some(t) = token {
        builder = builder.header("authorization", format!("Bearer {t}"));
    }
    let body_bytes = match body {
        Some(v) => Bytes::from(serde_json::to_vec(&v).unwrap()),
        None => Bytes::new(),
    };
    let res = client
        .request(builder.body(Full::new(body_bytes)).unwrap())
        .await
        .unwrap();
    let status = res.status().as_u16();
    let collected = res.into_body().collect().await.unwrap().to_bytes();
    let value = if collected.is_empty() {
        Value::Null
    } else {
        serde_json::from_slice(&collected).unwrap_or(Value::String(
            String::from_utf8_lossy(&collected).into_owned(),
        ))
    };
    (status, value)
}

async fn admin(servers: &Servers, method: &str, path: &str, body: Option<Value>) -> (u16, Value) {
    http_json(
        method,
        &format!("{}{path}", servers.admin),
        Some(ADMIN_TOKEN),
        body,
    )
    .await
}

/// Registers a parent with a family and one child; returns `(session token, family id)`.
async fn parent_with_family(servers: &Servers) -> (String, String) {
    let (status, body) = http_json(
        "POST",
        &format!("{}/auth/register", servers.public),
        None,
        Some(json!({ "name": "Ana", "email": "ana@example.com", "password": "password123" })),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    let token = body["token"].as_str().unwrap().to_string();
    let (status, body) = http_json(
        "POST",
        &format!("{}/families", servers.public),
        Some(&token),
        Some(json!({ "name": "Casa", "child_name": "Baby" })),
    )
    .await;
    assert_eq!(status, 200, "{body}");
    (token, body["family"]["id"].as_str().unwrap().to_string())
}

fn new_public_key() -> String {
    loop {
        let bytes: [u8; 32] = rand::random();
        if let Ok(key) = SigningKey::from_slice(&bytes) {
            return STANDARD.encode(key.verifying_key().to_encoded_point(false).as_bytes());
        }
    }
}

async fn redeem(servers: &Servers, invite: &Value, name: &str) -> (u16, Value) {
    http_json(
        "POST",
        &format!("{}/invites/redeem", servers.public),
        None,
        Some(json!({
            "invite_id": invite["id"],
            "secret": invite["secret"],
            "name": name,
            "public_key": new_public_key(),
            "device_name": format!("{name}'s iPhone"),
        })),
    )
    .await
}

async fn me_status(servers: &Servers, token: &str) -> u16 {
    http_json("GET", &format!("{}/me", servers.public), Some(token), None)
        .await
        .0
}

#[tokio::test]
async fn admin_routes_need_the_token_and_do_not_exist_on_the_public_listener() {
    let servers = spawn_servers().await;
    let url = format!("{}/admin/status", servers.admin);

    assert_eq!(http_json("GET", &url, None, None).await.0, 401);
    assert_eq!(http_json("GET", &url, Some("wrong"), None).await.0, 401);
    // Unknown paths are gated too, so the listener reveals nothing without the token.
    let unknown = format!("{}/admin/nope", servers.admin);
    assert_eq!(http_json("GET", &unknown, None, None).await.0, 401);

    let (status, body) = http_json("GET", &url, Some(ADMIN_TOKEN), None).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["service"], "benito-server");

    // Tailscale Serve and the LAN listener forward to the public router: no admin there,
    // even for a caller who somehow has the token.
    for path in ["/admin/status", "/admin/people", "/admin/backups"] {
        let public = format!("{}{path}", servers.public);
        assert_eq!(
            http_json("GET", &public, Some(ADMIN_TOKEN), None).await.0,
            404,
            "{path} must not be routed publicly"
        );
    }
    std::fs::remove_dir_all(servers.dir).unwrap();
}

#[tokio::test]
async fn status_glance_and_people_describe_the_seeded_family() {
    let servers = spawn_servers().await;
    let (token, family_id) = parent_with_family(&servers).await;

    let (_, children) = http_json(
        "GET",
        &format!("{}/children", servers.public),
        Some(&token),
        None,
    )
    .await;
    let child_id = children[0]["id"].as_str().unwrap().to_string();
    let (status, event) = http_json(
        "POST",
        &format!("{}/events", servers.public),
        Some(&token),
        Some(json!({ "child_id": child_id, "type": "diaper", "subtype": "wet" })),
    )
    .await;
    assert_eq!(status, 200, "{event}");
    let (status, timer) = http_json(
        "POST",
        &format!("{}/timers", servers.public),
        Some(&token),
        Some(json!({ "child_id": child_id, "kind": "sleep" })),
    )
    .await;
    assert_eq!(status, 200, "{timer}");

    let (status, body) = admin(&servers, "GET", "/admin/status", None).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["counts"]["users"], 1);
    assert_eq!(body["counts"]["families"], 1);
    assert_eq!(body["counts"]["children"], 1);
    assert_eq!(body["counts"]["events"], 1);
    assert_eq!(body["sync_connections"], 0);
    assert!(body["last_event_at"].is_string(), "{body}");
    assert!(body["database"]["size_bytes"].as_u64().unwrap() > 0);
    assert_eq!(body["backup"]["enabled"], true);
    assert_eq!(body["backup"]["latest"], Value::Null);

    let (status, body) = admin(&servers, "GET", "/admin/glance", None).await;
    assert_eq!(status, 200, "{body}");
    let child = &body["children"][0];
    assert_eq!(child["child_name"], "Baby");
    assert_eq!(child["family_name"], "Casa");
    assert_eq!(child["last_diaper"]["subtype"], "wet");
    assert_eq!(child["last_feed"], Value::Null);
    assert_eq!(child["active_timer"]["kind"], "sleep");
    assert_eq!(child["active_timer"]["state"], "running");

    let (status, body) = admin(&servers, "GET", "/admin/people", None).await;
    assert_eq!(status, 200, "{body}");
    let family = &body["families"][0];
    assert_eq!(family["id"], family_id.as_str());
    assert_eq!(family["children"][0]["name"], "Baby");
    assert_eq!(family["members"].as_array().unwrap().len(), 1);
    assert_eq!(family["members"][0]["name"], "Ana");
    assert_eq!(family["members"][0]["role"], "parent");
    assert_eq!(family["members"][0]["email"], "ana@example.com");
    assert_eq!(family["members"][0]["is_you"], false);
    assert!(
        !body.to_string().contains("password"),
        "no credential material in the people listing"
    );
    std::fs::remove_dir_all(servers.dir).unwrap();
}

#[tokio::test]
async fn admin_invite_lets_a_new_phone_in_and_admin_can_shut_it_out_again() {
    let servers = spawn_servers().await;

    // No family yet: there is nothing to invite into.
    let (status, body) = admin(&servers, "POST", "/admin/invites", Some(json!({}))).await;
    assert_eq!(status, 404, "{body}");

    let (_, family_id) = parent_with_family(&servers).await;

    // Minted without any signed-in parent: the lost-phone recovery path.
    let (status, invite) = admin(&servers, "POST", "/admin/invites", Some(json!({}))).await;
    assert_eq!(status, 200, "{invite}");
    assert_eq!(invite["role"], "parent");
    assert_eq!(invite["family_id"], family_id.as_str());
    assert_eq!(invite["inviter_name"], "Ana");
    assert!(invite["secret"].as_str().is_some_and(|s| s.len() >= 32));

    let (status, joined) = redeem(&servers, &invite, "Ben").await;
    assert_eq!(status, 200, "{joined}");
    let ben_token = joined["token"].as_str().unwrap().to_string();
    let ben_id = joined["user"]["id"].as_str().unwrap().to_string();
    let ben_device = joined["device_id"].as_str().unwrap().to_string();
    assert_eq!(joined["role"], "parent");
    assert_eq!(me_status(&servers, &ben_token).await, 200);
    assert_eq!(redeem(&servers, &invite, "Cy").await.0, 404, "single use");

    let (_, people) = admin(&servers, "GET", "/admin/people", None).await;
    let members = people["families"][0]["members"].as_array().unwrap();
    assert_eq!(members.len(), 2);
    assert_eq!(members[1]["name"], "Ben");
    assert_eq!(members[1]["devices"][0]["id"], ben_device.as_str());
    assert_eq!(members[1]["devices"][0]["name"], "Ben's iPhone");

    // Revoking the device ends the session it minted.
    let device_path = format!("/admin/devices/{ben_device}");
    assert_eq!(admin(&servers, "DELETE", &device_path, None).await.0, 200);
    assert_eq!(me_status(&servers, &ben_token).await, 401);
    assert_eq!(admin(&servers, "DELETE", &device_path, None).await.0, 404);
    let (_, people) = admin(&servers, "GET", "/admin/people", None).await;
    assert_eq!(
        people["families"][0]["members"][1]["devices"],
        json!([]),
        "revoked devices are not listed"
    );

    // Removing the person takes them off the family.
    let member_path = format!("/admin/families/{family_id}/members/{ben_id}");
    assert_eq!(admin(&servers, "DELETE", &member_path, None).await.0, 200);
    assert_eq!(admin(&servers, "DELETE", &member_path, None).await.0, 404);
    let (_, people) = admin(&servers, "GET", "/admin/people", None).await;
    assert_eq!(
        people["families"][0]["members"].as_array().unwrap().len(),
        1
    );

    // The last parent stays: without one, nobody could ever be invited again.
    let ana_id = people["families"][0]["members"][0]["user_id"]
        .as_str()
        .unwrap()
        .to_string();
    let last_parent_path = format!("/admin/families/{family_id}/members/{ana_id}");
    let (status, body) = admin(&servers, "DELETE", &last_parent_path, None).await;
    assert_eq!(status, 409, "{body}");
    let (_, people) = admin(&servers, "GET", "/admin/people", None).await;
    assert_eq!(
        people["families"][0]["members"][0]["user_id"],
        ana_id.as_str()
    );

    // A caregiver invite with an end date, listed as pending, then revoked before use.
    let (status, caregiver) = admin(
        &servers,
        "POST",
        "/admin/invites",
        Some(json!({ "family_id": family_id, "role": "caregiver", "access_hours": 8, "label": "Sitter" })),
    )
    .await;
    assert_eq!(status, 200, "{caregiver}");
    assert_eq!(caregiver["access_hours"], 8);
    let (_, people) = admin(&servers, "GET", "/admin/people", None).await;
    let pending = people["families"][0]["invites"].as_array().unwrap();
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0]["label"], "Sitter");
    assert!(pending[0].get("secret").is_none(), "secret is shown once");
    let invite_path = format!("/admin/invites/{}", caregiver["id"].as_str().unwrap());
    assert_eq!(admin(&servers, "DELETE", &invite_path, None).await.0, 200);
    assert_eq!(redeem(&servers, &caregiver, "Sitter").await.0, 404);

    let (status, body) = admin(
        &servers,
        "POST",
        "/admin/invites",
        Some(json!({ "role": "owner" })),
    )
    .await;
    assert_eq!(status, 400, "{body}");
    std::fs::remove_dir_all(servers.dir).unwrap();
}

async fn admin_text(servers: &Servers, path: &str) -> (u16, String) {
    let client = Client::builder(TokioExecutor::new()).build_http::<Full<Bytes>>();
    let request = Request::builder()
        .method("GET")
        .uri(format!("{}{path}", servers.admin))
        .header("authorization", format!("Bearer {ADMIN_TOKEN}"))
        .body(Full::new(Bytes::new()))
        .unwrap();
    let res = client.request(request).await.unwrap();
    let status = res.status().as_u16();
    let body = res.into_body().collect().await.unwrap().to_bytes();
    (status, String::from_utf8_lossy(&body).into_owned())
}

#[tokio::test]
async fn export_covers_the_family_and_honours_child_and_date_range() {
    let servers = spawn_servers().await;
    let (token, family_id) = parent_with_family(&servers).await;
    let (_, second) = http_json(
        "POST",
        &format!("{}/children", servers.public),
        Some(&token),
        Some(json!({ "name": "Pip" })),
    )
    .await;
    let (_, children) = http_json(
        "GET",
        &format!("{}/children", servers.public),
        Some(&token),
        None,
    )
    .await;
    let baby = children
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["name"] == "Baby")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let pip = second["id"].as_str().unwrap().to_string();

    let log = |child: String, subtype: &'static str, at: &'static str| {
        let url = format!("{}/events", servers.public);
        let token = token.clone();
        async move {
            let (status, body) = http_json(
                "POST",
                &url,
                Some(&token),
                Some(json!({ "child_id": child, "type": "diaper", "subtype": subtype, "started_at": at })),
            )
            .await;
            assert_eq!(status, 200, "{body}");
            body["id"].as_str().unwrap().to_string()
        }
    };
    log(baby.clone(), "wet", "2026-10-01T10:00:00Z").await;
    log(baby.clone(), "dirty", "2026-10-02T10:00:00.250Z").await;
    let deleted = log(baby.clone(), "both", "2026-10-02T11:00:00Z").await;
    log(pip.clone(), "wet", "2026-10-02T12:00:00Z").await;
    let (status, _) = http_json(
        "DELETE",
        &format!("{}/events/{deleted}", servers.public),
        Some(&token),
        None,
    )
    .await;
    assert_eq!(status, 200);

    let subtypes = |csv: &str| -> Vec<String> {
        csv.lines()
            .skip(1)
            .map(|line| {
                let cols: Vec<&str> = line.split(',').collect();
                format!("{}:{}", &cols[1][..4], cols[3])
            })
            .collect()
    };
    let b = &baby[..4];
    let p = &pip[..4];

    let (status, all) = admin_text(&servers, "/admin/export.csv").await;
    assert_eq!(status, 200, "{all}");
    assert!(
        all.starts_with("id,child_id,type,subtype,started_at"),
        "{all}"
    );
    assert_eq!(
        subtypes(&all),
        vec![format!("{b}:wet"), format!("{b}:dirty"), format!("{p}:wet")],
        "every child, oldest first, deleted entries left out"
    );

    let (_, one_child) = admin_text(
        &servers,
        &format!("/admin/export.csv?family_id={family_id}&child_id={pip}"),
    )
    .await;
    assert_eq!(subtypes(&one_child), vec![format!("{p}:wet")]);

    // `from` is inclusive and `to` exclusive; fractional seconds must not confuse the range.
    let (_, ranged) = admin_text(
        &servers,
        "/admin/export.csv?from=2026-10-02T10:00:00.250Z&to=2026-10-02T12:00:00Z",
    )
    .await;
    assert_eq!(subtypes(&ranged), vec![format!("{b}:dirty")]);

    let (status, bundle) = admin(&servers, "GET", "/admin/export.json", None).await;
    assert_eq!(status, 200, "{bundle}");
    assert_eq!(bundle["family"]["id"], family_id.as_str());
    assert_eq!(bundle["children"].as_array().unwrap().len(), 2);
    assert_eq!(
        bundle["events"].as_array().unwrap().len(),
        4,
        "the full bundle keeps tombstones"
    );

    let missing = "/admin/export.csv?family_id=00000000-0000-0000-0000-000000000000";
    assert_eq!(admin_text(&servers, missing).await.0, 404);
    std::fs::remove_dir_all(servers.dir).unwrap();
}

#[tokio::test]
async fn backups_run_on_demand_and_show_up_in_the_list_and_status() {
    let servers = spawn_servers().await;
    parent_with_family(&servers).await;

    let (status, list) = admin(&servers, "GET", "/admin/backups", None).await;
    assert_eq!(status, 200, "{list}");
    assert_eq!(list["enabled"], true);
    assert_eq!(list["backups"], json!([]));

    let (status, report) = admin(&servers, "POST", "/admin/backups", None).await;
    assert_eq!(status, 200, "{report}");
    assert_eq!(report["users"], 1);
    let name = report["name"].as_str().unwrap();
    assert!(
        name.starts_with("benito-") && name.ends_with(".db"),
        "{name}"
    );
    assert!(std::path::Path::new(report["path"].as_str().unwrap()).is_file());

    let (_, list) = admin(&servers, "GET", "/admin/backups", None).await;
    assert_eq!(list["backups"][0]["name"], name);
    let (_, status_body) = admin(&servers, "GET", "/admin/status", None).await;
    assert_eq!(status_body["backup"]["latest"]["name"], name);
    assert_eq!(status_body["backup"]["last_error"], Value::Null);
    std::fs::remove_dir_all(servers.dir).unwrap();
}

#[test]
fn handoff_file_is_private_names_the_listener_and_goes_away_on_drop() {
    let dir = std::env::temp_dir().join(format!("benito-handoff-{}", uuid::Uuid::new_v4()));
    let path = dir.join("admin.json");
    let addr = "127.0.0.1:53012".parse().unwrap();
    let handoff =
        benito_server::admin::Handoff::write(&path, addr, "s3cret", chrono::Utc::now()).unwrap();

    let body: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert_eq!(body["url"], "http://127.0.0.1:53012");
    assert_eq!(body["token"], "s3cret");
    assert_eq!(body["pid"], std::process::id());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }

    drop(handoff);
    assert!(!path.exists(), "a clean shutdown leaves no stale token");
    std::fs::remove_dir_all(dir).unwrap();
}
