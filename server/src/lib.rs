pub mod apns;
pub mod auth;
pub mod db;
pub mod device_auth;
pub mod envfile;
pub mod lan;
pub mod models;
pub mod routes;
pub mod sync;

use crate::apns::ApnsClient;
use crate::db::Db;
use crate::sync::SyncHub;

#[derive(Clone)]
pub struct AppState {
    pub db: Db,
    pub sync: SyncHub,
    pub session_secret: String,
    pub apns: ApnsClient,
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
    })
}
