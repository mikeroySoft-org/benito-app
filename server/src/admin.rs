//! Loopback admin API for the Mac server app (docs/plans/mac-server-app.md §2.4).
//!
//! Served on its own listener, never merged into the public router: Tailscale Serve and
//! reverse proxies forward to the public port from loopback, so "the request came from
//! 127.0.0.1" proves nothing there. Every route needs the bearer token from the handoff file.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Context;
use axum::{
    extract::{Path as UrlPath, Query, Request, State},
    http::{header::AUTHORIZATION, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get},
    Json, Router,
};
use chrono::{DateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::auth::AuthError;
use crate::backup::{BackupReport, Snapshot};
use crate::device_auth::{digests_match, hash_secret};
use crate::models::ExportBundle;
use crate::models::{Event, Timer};
use crate::routes::export::{self, CsvScope};
use crate::routes::sharing::{
    self, CreateInviteRequest, InviteResponse, InviteTerms, Member, ROLE_PARENT,
};
use crate::routes::state::load_baby_state;
use crate::AppState;

pub fn router(state: AppState, token: &str) -> Router {
    let token: Arc<str> = Arc::from(token);
    Router::new()
        .route("/admin/status", get(status))
        .route("/admin/glance", get(glance))
        .route("/admin/people", get(people))
        .route("/admin/invites", axum::routing::post(create_invite))
        .route("/admin/invites/{id}", delete(revoke_invite))
        .route("/admin/devices/{id}", delete(revoke_device))
        .route(
            "/admin/families/{family_id}/members/{user_id}",
            delete(remove_member),
        )
        .route("/admin/backups", get(list_backups).post(run_backup))
        .route("/admin/export.csv", get(export_csv))
        .route("/admin/export.json", get(export_json))
        .layer(middleware::from_fn_with_state(token, require_token))
        .with_state(state)
}

async fn require_token(
    State(expected): State<Arc<str>>,
    request: Request,
    next: Next,
) -> Result<Response, AuthError> {
    let given = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(AuthError::Unauthorized)?;
    if !digests_match(&hash_secret(given), &hash_secret(&expected)) {
        return Err(AuthError::Unauthorized);
    }
    Ok(next.run(request).await)
}

// MARK: - Handoff file

/// `admin.json` next to the database unless `BENITO_ADMIN_FILE` says otherwise.
pub fn default_handoff_path(db_path: &Path) -> PathBuf {
    db_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."))
        .join("admin.json")
}

/// The file a local client reads to find and authenticate to the admin listener. Removed
/// when dropped, so a clean shutdown leaves nothing stale behind.
#[derive(Debug)]
pub struct Handoff {
    path: PathBuf,
}

impl Handoff {
    pub fn write(
        path: &Path,
        addr: SocketAddr,
        token: &str,
        started_at: DateTime<Utc>,
    ) -> anyhow::Result<Self> {
        let body = serde_json::to_vec(&json!({
            "url": format!("http://{addr}"),
            "token": token,
            "pid": std::process::id(),
            "started_at": started_at.to_rfc3339(),
        }))?;
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        // Written beside the target and renamed, so a reader never sees half a file.
        let mut tmp = path.as_os_str().to_os_string();
        tmp.push(format!(".{}.tmp", std::process::id()));
        let tmp = PathBuf::from(tmp);
        let _ = std::fs::remove_file(&tmp);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&tmp)
            .with_context(|| format!("create {}", tmp.display()))?;
        std::io::Write::write_all(&mut file, &body)?;
        drop(file);
        std::fs::rename(&tmp, path).with_context(|| format!("write {}", path.display()))?;
        Ok(Self {
            path: path.to_path_buf(),
        })
    }
}

impl Drop for Handoff {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

// MARK: - Status

#[derive(Serialize)]
struct DatabaseStatus {
    path: PathBuf,
    size_bytes: u64,
    wal_bytes: u64,
}

#[derive(Serialize)]
struct Counts {
    users: i64,
    families: i64,
    children: i64,
    events: i64,
    devices: i64,
}

#[derive(Serialize)]
struct BackupStatus {
    enabled: bool,
    dir: Option<PathBuf>,
    keep: usize,
    interval_hours: u64,
    latest: Option<Snapshot>,
    last_error: Option<String>,
}

#[derive(Serialize)]
struct Status {
    service: &'static str,
    version: &'static str,
    pid: u32,
    server_id: String,
    started_at: DateTime<Utc>,
    uptime_seconds: i64,
    database: DatabaseStatus,
    counts: Counts,
    last_event_at: Option<DateTime<Utc>>,
    listeners: Vec<String>,
    advertised_urls: Vec<String>,
    bonjour_name: Option<String>,
    sync_connections: usize,
    apns_configured: bool,
    backup: BackupStatus,
}

fn file_size(path: &Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn backup_status(state: &AppState) -> BackupStatus {
    match &state.backups {
        Some(service) => BackupStatus {
            enabled: true,
            dir: Some(service.dir().to_path_buf()),
            keep: service.keep(),
            interval_hours: service.interval_hours(),
            latest: service.list().ok().and_then(|all| all.into_iter().next()),
            last_error: service.last_error(),
        },
        None => BackupStatus {
            enabled: false,
            dir: None,
            keep: crate::backup::DEFAULT_KEEP,
            interval_hours: crate::backup::DEFAULT_INTERVAL_HOURS,
            latest: None,
            last_error: None,
        },
    }
}

async fn status(State(state): State<AppState>) -> Result<Json<Status>, AuthError> {
    let sync_connections = state.sync.connection_count().await;
    let now = Utc::now();
    let info = &state.info;
    let mut wal = info.db_path.as_os_str().to_os_string();
    wal.push("-wal");
    let database = DatabaseStatus {
        size_bytes: file_size(&info.db_path),
        wal_bytes: file_size(Path::new(&wal)),
        path: info.db_path.clone(),
    };

    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let count = |table: &str| -> Result<i64, AuthError> {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .map_err(|_| AuthError::Internal)
    };
    let counts = Counts {
        users: count("users")?,
        families: count("families")?,
        children: count("children")?,
        events: count("events WHERE deleted_at IS NULL")?,
        devices: count("devices WHERE revoked_at IS NULL")?,
    };
    let last_event_at: Option<String> = conn
        .query_row("SELECT MAX(updated_at) FROM events", [], |r| r.get(0))
        .map_err(|_| AuthError::Internal)?;
    Ok(Json(Status {
        service: "benito-server",
        version: env!("CARGO_PKG_VERSION"),
        pid: std::process::id(),
        server_id: sharing::server_id(&conn),
        started_at: info.started_at,
        uptime_seconds: (now - info.started_at).num_seconds().max(0),
        database,
        counts,
        last_event_at: last_event_at.as_deref().and_then(sharing::parse_time),
        listeners: info.listeners.iter().map(SocketAddr::to_string).collect(),
        advertised_urls: sharing::advertised_urls(),
        bonjour_name: info.bonjour_name.clone(),
        sync_connections,
        apns_configured: state.apns.is_enabled(),
        backup: backup_status(&state),
    }))
}

// MARK: - Glance

#[derive(Serialize)]
struct ChildGlance {
    child_id: Uuid,
    child_name: String,
    family_id: String,
    family_name: String,
    last_feed: Option<Event>,
    last_diaper: Option<Event>,
    last_medicine: Option<Event>,
    active_timer: Option<Timer>,
}

#[derive(Serialize)]
struct Glance {
    children: Vec<ChildGlance>,
}

async fn glance(State(state): State<AppState>) -> Result<Json<Glance>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let mut stmt = conn
        .prepare(
            "SELECT c.id, c.name, f.id, f.name FROM children c
             JOIN families f ON f.id = c.family_id
             ORDER BY f.created_at ASC, c.created_at ASC",
        )
        .map_err(|_| AuthError::Internal)?;
    let rows: Vec<(String, String, String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .map_err(|_| AuthError::Internal)?
        .filter_map(Result::ok)
        .collect();
    let mut children = Vec::with_capacity(rows.len());
    for (child_id, child_name, family_id, family_name) in rows {
        let child_id = Uuid::parse_str(&child_id).map_err(|_| AuthError::Internal)?;
        let baby = load_baby_state(&conn, child_id)?;
        children.push(ChildGlance {
            child_id,
            child_name,
            family_id,
            family_name,
            last_feed: baby.last_feed,
            last_diaper: baby.last_diaper,
            last_medicine: baby.last_medicine,
            active_timer: baby.active_timer,
        });
    }
    Ok(Json(Glance { children }))
}

// MARK: - People and devices

#[derive(Serialize)]
struct ChildRef {
    id: String,
    name: String,
}

#[derive(Serialize)]
struct FamilyPeople {
    id: String,
    name: String,
    created_at: String,
    children: Vec<ChildRef>,
    members: Vec<Member>,
    invites: Vec<InviteResponse>,
}

#[derive(Serialize)]
struct People {
    families: Vec<FamilyPeople>,
}

async fn people(State(state): State<AppState>) -> Result<Json<People>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let mut stmt = conn
        .prepare("SELECT id, name, created_at FROM families ORDER BY created_at ASC")
        .map_err(|_| AuthError::Internal)?;
    let rows: Vec<(String, String, String)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
        .map_err(|_| AuthError::Internal)?
        .filter_map(Result::ok)
        .collect();
    let mut child_stmt = conn
        .prepare("SELECT id, name FROM children WHERE family_id = ?1 ORDER BY created_at ASC")
        .map_err(|_| AuthError::Internal)?;
    let mut families = Vec::with_capacity(rows.len());
    for (id, name, created_at) in rows {
        let children = child_stmt
            .query_map(params![id], |r| {
                Ok(ChildRef {
                    id: r.get(0)?,
                    name: r.get(1)?,
                })
            })
            .map_err(|_| AuthError::Internal)?
            .filter_map(Result::ok)
            .collect();
        families.push(FamilyPeople {
            children,
            members: sharing::members_of(&conn, &id, None)?,
            invites: sharing::pending_invites(&conn, &id)?,
            id,
            name,
            created_at,
        });
    }
    Ok(Json(People { families }))
}

#[derive(Debug, Deserialize, Default)]
struct AdminInviteRequest {
    /// May be omitted when the server has exactly one family.
    #[serde(default)]
    family_id: Option<String>,
    #[serde(flatten)]
    terms: CreateInviteRequest,
}

fn resolve_family(conn: &Connection, requested: Option<&str>) -> Result<String, AuthError> {
    if let Some(id) = requested {
        return conn
            .query_row("SELECT id FROM families WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| AuthError::Internal)?
            .ok_or_else(|| AuthError::NotFound("family not found".into()));
    }
    let mut stmt = conn
        .prepare("SELECT id FROM families LIMIT 2")
        .map_err(|_| AuthError::Internal)?;
    let mut ids: Vec<String> = stmt
        .query_map([], |r| r.get(0))
        .map_err(|_| AuthError::Internal)?
        .filter_map(Result::ok)
        .collect();
    match ids.len() {
        0 => Err(AuthError::NotFound(
            "no family yet; create one in the Benito app first".into(),
        )),
        1 => Ok(ids.remove(0)),
        _ => Err(AuthError::BadRequest(
            "family_id is required: this server has more than one family".into(),
        )),
    }
}

/// Invites must name a creator (`family_invites.created_by`); the admin has no account, so
/// the family's longest-standing parent stands in.
fn first_parent(conn: &Connection, family_id: &str) -> Result<(String, String), AuthError> {
    conn.query_row(
        "SELECT u.id, u.name FROM family_members fm JOIN users u ON u.id = fm.user_id
         WHERE fm.family_id = ?1 AND fm.role = ?2
         ORDER BY fm.joined_at ASC LIMIT 1",
        params![family_id, ROLE_PARENT],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .optional()
    .map_err(|_| AuthError::Internal)?
    .ok_or_else(|| AuthError::Conflict("this family has no parent to create the invite for".into()))
}

async fn create_invite(
    State(state): State<AppState>,
    body: Option<Json<AdminInviteRequest>>,
) -> Result<Json<InviteResponse>, AuthError> {
    let body = body.map(|Json(b)| b).unwrap_or_default();
    let terms = InviteTerms::parse(body.terms)?;
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = resolve_family(&conn, body.family_id.as_deref())?;
    let (creator_id, creator_name) = first_parent(&conn, &family_id)?;
    Ok(Json(sharing::insert_invite(
        &conn,
        &family_id,
        &creator_id,
        &creator_name,
        terms,
    )?))
}

async fn revoke_invite(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let changed = conn
        .execute(
            "UPDATE family_invites SET revoked_at = ?2
             WHERE id = ?1 AND used_at IS NULL AND revoked_at IS NULL",
            params![id, Utc::now().to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
    if changed == 0 {
        return Err(AuthError::NotFound("no pending invite with that id".into()));
    }
    Ok(Json(json!({ "revoked": true })))
}

/// Revokes one device key and ends the sessions it minted. Sockets that device already has
/// open keep streaming until they reconnect, as with `POST /families/leave`.
async fn revoke_device(
    State(state): State<AppState>,
    UrlPath(id): UrlPath<String>,
) -> Result<Json<serde_json::Value>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let changed = conn
        .execute(
            "UPDATE devices SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL",
            params![id, Utc::now().to_rfc3339()],
        )
        .map_err(|_| AuthError::Internal)?;
    if changed == 0 {
        return Err(AuthError::NotFound("no active device with that id".into()));
    }
    conn.execute("DELETE FROM sessions WHERE device_id = ?1", params![id])
        .map_err(|_| AuthError::Internal)?;
    Ok(Json(json!({ "revoked": true })))
}

async fn remove_member(
    State(state): State<AppState>,
    UrlPath((family_id, user_id)): UrlPath<(String, String)>,
) -> Result<Json<serde_json::Value>, AuthError> {
    {
        // Invites minted here are attributed to a parent, and only a parent can invite from a
        // phone: a family without one could not let anybody in again.
        let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
        let role: Option<String> = conn
            .query_row(
                "SELECT role FROM family_members WHERE family_id = ?1 AND user_id = ?2",
                params![family_id, user_id],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| AuthError::Internal)?;
        if role.as_deref() == Some(ROLE_PARENT) {
            let other_parents: i64 = conn
                .query_row(
                    "SELECT COUNT(*) FROM family_members
                     WHERE family_id = ?1 AND role = ?2 AND user_id != ?3",
                    params![family_id, ROLE_PARENT, user_id],
                    |r| r.get(0),
                )
                .map_err(|_| AuthError::Internal)?;
            if other_parents == 0 {
                return Err(AuthError::Conflict(
                    "this is the family's only parent; invite another parent before removing them"
                        .into(),
                ));
            }
        }
    }
    sharing::remove_family_member(&state, &family_id, &user_id)?;
    Ok(Json(json!({ "removed": true })))
}

// MARK: - Backups

#[derive(Serialize)]
struct BackupList {
    enabled: bool,
    dir: Option<PathBuf>,
    backups: Vec<Snapshot>,
}

fn failure(status: StatusCode, message: String) -> Response {
    (status, Json(json!({ "error": message }))).into_response()
}

async fn list_backups(State(state): State<AppState>) -> Result<Json<BackupList>, Response> {
    let Some(service) = state.backups.clone() else {
        return Ok(Json(BackupList {
            enabled: false,
            dir: None,
            backups: Vec::new(),
        }));
    };
    let backups = service
        .list()
        .map_err(|e| failure(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")))?;
    Ok(Json(BackupList {
        enabled: true,
        dir: Some(service.dir().to_path_buf()),
        backups,
    }))
}

async fn run_backup(State(state): State<AppState>) -> Result<Json<BackupReport>, Response> {
    let Some(service) = state.backups.clone() else {
        return Err(failure(
            StatusCode::CONFLICT,
            "backups are not configured (set BENITO_BACKUP_DIR)".into(),
        ));
    };
    match tokio::task::spawn_blocking(move || service.run()).await {
        Ok(Ok(report)) => Ok(Json(report)),
        Ok(Err(e)) => Err(failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("backup failed: {e:#}"),
        )),
        Err(e) => Err(failure(
            StatusCode::INTERNAL_SERVER_ERROR,
            format!("backup task failed: {e}"),
        )),
    }
}

// MARK: - Export

#[derive(Debug, Deserialize)]
struct ExportQuery {
    #[serde(default)]
    family_id: Option<String>,
    #[serde(default)]
    child_id: Option<String>,
    /// Inclusive, on the event's start.
    #[serde(default)]
    from: Option<DateTime<Utc>>,
    /// Exclusive, on the event's start.
    #[serde(default)]
    to: Option<DateTime<Utc>>,
}

async fn export_csv(
    State(state): State<AppState>,
    Query(query): Query<ExportQuery>,
) -> Result<impl IntoResponse, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = resolve_family(&conn, query.family_id.as_deref())?;
    let body = export::events_csv(
        &conn,
        &CsvScope {
            family_id: &family_id,
            child_id: query.child_id.as_deref(),
            from: query.from,
            to: query.to,
        },
    )?;
    Ok(export::csv_response(body))
}

async fn export_json(
    State(state): State<AppState>,
    Query(query): Query<ExportQuery>,
) -> Result<Json<ExportBundle>, AuthError> {
    let conn = state.db.lock().map_err(|_| AuthError::Internal)?;
    let family_id = resolve_family(&conn, query.family_id.as_deref())?;
    Ok(Json(export::family_bundle(&conn, &family_id)?))
}
