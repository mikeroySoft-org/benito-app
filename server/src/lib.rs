pub mod admin;
pub mod apns;
pub mod auth;
pub mod backup;
pub mod db;
pub mod device_auth;
pub mod envfile;
pub mod instance_lock;
pub mod lan;
pub mod models;
pub mod routes;
pub mod sync;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use chrono::{DateTime, Utc};

use crate::apns::ApnsClient;
use crate::backup::BackupService;
use crate::db::Db;
use crate::sync::SyncHub;

/// Facts about this process that the admin API reports.
#[derive(Debug, Clone)]
pub struct ServerInfo {
    pub db_path: PathBuf,
    pub started_at: DateTime<Utc>,
    /// Public listeners (`BIND_ADDR`); the admin listener is not one of them.
    pub listeners: Vec<SocketAddr>,
    /// Set while the server advertises `_benito._tcp`.
    pub bonjour_name: Option<String>,
}

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub sync: SyncHub,
    pub session_secret: String,
    pub apns: ApnsClient,
    pub info: Arc<ServerInfo>,
    /// `None` unless `BENITO_BACKUP_DIR` is set.
    pub backups: Option<Arc<BackupService>>,
}

pub fn build_router(state: AppState) -> axum::Router {
    use axum::Router;
    use tower_http::cors::{Any, CorsLayer};
    use tower_http::trace::TraceLayer;

    Router::new()
        .merge(routes::router())
        .layer(
            CorsLayer::new()
                .allow_origin(Any)
                .allow_methods(Any)
                .allow_headers(Any),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}

pub fn app_state(
    database_path: &str,
    session_secret: impl Into<String>,
) -> anyhow::Result<AppState> {
    let db = db::open(database_path)?;
    Ok(AppState {
        db,
        sync: SyncHub::new(),
        session_secret: session_secret.into(),
        apns: ApnsClient::from_env(),
        info: Arc::new(ServerInfo {
            db_path: PathBuf::from(database_path),
            started_at: Utc::now(),
            listeners: Vec::new(),
            bonjour_name: None,
        }),
        backups: None,
    })
}
