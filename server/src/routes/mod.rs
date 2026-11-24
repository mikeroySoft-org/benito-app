mod auth_routes;
mod events;
mod export;
mod health;
mod live_activity;
pub mod sharing;
mod state;
mod summary;
mod timers;

use axum::{
    extract::{Query, State, WebSocketUpgrade},
    response::Response,
    routing::{delete, get, patch, post},
    Router,
};
use serde::Deserialize;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/health", get(health::health))
        .route("/auth/register", post(auth_routes::register))
        .route("/auth/login", post(auth_routes::login))
        .route("/server/info", get(sharing::server_info))
        .route("/auth/device/signup", post(sharing::device_signup))
        .route("/auth/device/session", post(sharing::device_session))
        .route("/devices", post(sharing::register_device))
        .route("/families/members", get(sharing::list_members))
        .route(
            "/families/members/{user_id}",
            delete(sharing::remove_member),
        )
        .route(
            "/families/invites",
            post(sharing::create_invite).get(sharing::list_invites),
        )
        .route("/families/invites/{id}", delete(sharing::revoke_invite))
        .route("/invites/redeem", post(sharing::redeem_invite))
        .route(
            "/me",
            get(auth_routes::me).delete(auth_routes::delete_account),
        )
        .route("/families", post(auth_routes::create_family))
        .route("/families/join", post(auth_routes::join_family))
        .route("/families/leave", post(auth_routes::leave_family))
        .route(
            "/families/pairing-tokens",
            post(auth_routes::create_pairing_token),
        )
        .route("/families/pair", post(auth_routes::pair_with_token))
        .route("/families/invite/rotate", post(auth_routes::rotate_invite))
        .route(
            "/children",
            post(auth_routes::create_child).get(auth_routes::list_children),
        )
        .route(
            "/events",
            post(events::create_event).get(events::list_events),
        )
        .route(
            "/events/{id}",
            patch(events::update_event).delete(events::delete_event),
        )
        .route("/timeline", get(events::timeline))
        .route("/state", get(state::baby_state))
        .route(
            "/timers",
            post(timers::start_timer).get(timers::list_timers),
        )
        .route("/timers/{id}", patch(timers::adjust_timer))
        .route("/timers/{id}/pause", post(timers::pause_timer))
        .route("/timers/{id}/resume", post(timers::resume_timer))
        .route("/timers/{id}/stop", post(timers::stop_timer))
        .route("/export", get(export::export_json))
        .route("/export.csv", get(export::export_csv))
        .route("/summary/daily", get(summary::daily_summary))
        .route(
            "/live-activity/tokens",
            post(live_activity::register_token).delete(live_activity::delete_tokens),
        )
        .route("/sync", get(ws_sync))
}

#[derive(Debug, Deserialize)]
struct SyncQuery {
    token: Option<String>,
}

async fn ws_sync(
    State(state): State<AppState>,
    Query(q): Query<SyncQuery>,
    ws: WebSocketUpgrade,
) -> Response {
    let hub = state.sync.clone();
    let db = state.db.clone();
    let token = q.token;
    ws.on_upgrade(move |socket| hub.handle_socket(socket, db, token))
}
