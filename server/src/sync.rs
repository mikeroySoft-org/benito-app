//! Family-scoped WebSocket sync hub.
//!
//! Connections authenticate with a session token (first message or `?token=` query).
//! After auth they subscribe to an in-memory broadcast channel keyed by `family_id`.
//! Multi-instance deploys will need Redis (or similar) later; single SQLite process is fine for v1.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use chrono::{DateTime, Utc};
use futures_util::{SinkExt, StreamExt};
use rusqlite::params;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::{broadcast, Mutex, RwLock};
use uuid::Uuid;

use crate::auth::user_from_token;
use crate::db::Db;

static CLIENT_SEQ: AtomicU64 = AtomicU64::new(1);

const CHANNEL_CAPACITY: usize = 256;
const AUTH_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SyncEnvelope {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub payload: Value,
    pub at: DateTime<Utc>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_id: Option<String>,
}

impl SyncEnvelope {
    pub fn new(msg_type: impl Into<String>, payload: Value) -> Self {
        Self {
            msg_type: msg_type.into(),
            payload,
            at: Utc::now(),
            client_id: None,
        }
    }

    pub fn with_client_id(mut self, client_id: Option<String>) -> Self {
        self.client_id = client_id;
        self
    }

    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| {
            json!({
                "type": "error",
                "payload": { "message": "serialize failed" },
                "at": Utc::now().to_rfc3339()
            })
            .to_string()
        })
    }
}

#[derive(Clone)]
pub struct SyncHub {
    /// family_id → broadcast fan-out for that family's live clients
    channels: Arc<RwLock<HashMap<Uuid, broadcast::Sender<String>>>>,
    /// live connection count (diagnostics)
    clients: Arc<RwLock<HashMap<u64, Uuid>>>,
}

impl Default for SyncHub {
    fn default() -> Self {
        Self::new()
    }
}

impl SyncHub {
    pub fn new() -> Self {
        Self {
            channels: Arc::new(RwLock::new(HashMap::new())),
            clients: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Publish a sync envelope to every authenticated WS client in `family_id`.
    /// Includes the originating client (if any) so peers can de-dupe via `client_id`.
    pub fn publish_to_family(&self, family_id: Uuid, envelope: SyncEnvelope) {
        // Try without waiting: if channel exists, send; otherwise nobody is listening.
        if let Ok(guard) = self.channels.try_read() {
            if let Some(tx) = guard.get(&family_id) {
                let _ = tx.send(envelope.to_json());
            }
            return;
        }
        // Rare contention: spawn a best-effort send
        let hub = self.clone();
        tokio::spawn(async move {
            hub.publish_to_family_async(family_id, envelope).await;
        });
    }

    pub async fn publish_to_family_async(&self, family_id: Uuid, envelope: SyncEnvelope) {
        let guard = self.channels.read().await;
        if let Some(tx) = guard.get(&family_id) {
            let _ = tx.send(envelope.to_json());
        }
    }

    async fn family_sender(&self, family_id: Uuid) -> broadcast::Sender<String> {
        let mut guard = self.channels.write().await;
        guard
            .entry(family_id)
            .or_insert_with(|| {
                let (tx, _) = broadcast::channel(CHANNEL_CAPACITY);
                tx
            })
            .clone()
    }

    pub async fn handle_socket(self, socket: WebSocket, db: Db, query_token: Option<String>) {
        let conn_id = CLIENT_SEQ.fetch_add(1, Ordering::SeqCst);
        let (sender, mut receiver) = socket.split();
        let sender = Arc::new(Mutex::new(sender));

        let auth = match authenticate(&db, &mut receiver, &sender, query_token).await {
            Ok(a) => a,
            Err(msg) => {
                let env = SyncEnvelope::new("error", json!({ "message": msg }));
                let mut s = sender.lock().await;
                let _ = s.send(Message::Text(env.to_json().into())).await;
                let _ = s.send(Message::Close(None)).await;
                return;
            }
        };

        {
            let mut clients = self.clients.write().await;
            clients.insert(conn_id, auth.family_id);
        }

        let tx = self.family_sender(auth.family_id).await;
        let mut rx = tx.subscribe();

        let hello = SyncEnvelope::new(
            "hello",
            json!({
                "client_id": auth.client_id,
                "connection_id": conn_id,
                "family_id": auth.family_id,
                "user_id": auth.user_id,
                "message": "benito sync"
            }),
        )
        .with_client_id(Some(auth.client_id.clone()));

        {
            let mut s = sender.lock().await;
            if s.send(Message::Text(hello.to_json().into())).await.is_err() {
                self.drop_client(conn_id).await;
                return;
            }
        }

        tracing::info!(
            connection_id = conn_id,
            family_id = %auth.family_id,
            user_id = %auth.user_id,
            "ws client authenticated"
        );

        let send_sender = sender.clone();
        let mut send_task = tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(msg) => {
                        let mut s = send_sender.lock().await;
                        if s.send(Message::Text(msg.into())).await.is_err() {
                            break;
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });

        let hub = self.clone();
        let family_id = auth.family_id;
        let client_id = auth.client_id.clone();
        let recv_sender = sender.clone();
        let mut recv_task = tokio::spawn(async move {
            while let Some(Ok(msg)) = receiver.next().await {
                match msg {
                    Message::Text(t) => {
                        if let Err(e) = handle_client_text(&hub, family_id, &client_id, &t).await {
                            let env = SyncEnvelope::new("error", json!({ "message": e }));
                            let mut s = recv_sender.lock().await;
                            let _ = s.send(Message::Text(env.to_json().into())).await;
                        }
                    }
                    Message::Ping(p) => {
                        let mut s = recv_sender.lock().await;
                        let _ = s.send(Message::Pong(p)).await;
                    }
                    Message::Pong(_) => {}
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        });

        tokio::select! {
            _ = &mut send_task => recv_task.abort(),
            _ = &mut recv_task => send_task.abort(),
        }

        self.drop_client(conn_id).await;
        tracing::info!(connection_id = conn_id, "ws client disconnected");
    }

    async fn drop_client(&self, id: u64) {
        let mut clients = self.clients.write().await;
        clients.remove(&id);
    }
}

struct AuthInfo {
    user_id: Uuid,
    family_id: Uuid,
    client_id: String,
}

async fn authenticate(
    db: &Db,
    receiver: &mut futures_util::stream::SplitStream<WebSocket>,
    sender: &Arc<Mutex<futures_util::stream::SplitSink<WebSocket, Message>>>,
    query_token: Option<String>,
) -> Result<AuthInfo, String> {
    if let Some(token) = query_token {
        return resolve_auth(db, &token, None);
    }

    let deadline = tokio::time::sleep(AUTH_TIMEOUT);
    tokio::pin!(deadline);

    loop {
        tokio::select! {
            _ = &mut deadline => return Err("auth timeout: send {\"type\":\"auth\",\"payload\":{\"token\":\"...\"}}".into()),
            next = receiver.next() => {
                match next {
                    Some(Ok(Message::Text(t))) => {
                        let v: Value = serde_json::from_str(&t)
                            .map_err(|_| "auth message must be JSON".to_string())?;
                        let msg_type = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
                        if msg_type != "auth" {
                            let env = SyncEnvelope::new(
                                "error",
                                json!({ "message": "first message must be type=auth" }),
                            );
                            let mut s = sender.lock().await;
                            let _ = s.send(Message::Text(env.to_json().into())).await;
                            return Err("first message must be type=auth".into());
                        }
                        let payload = v.get("payload").cloned().unwrap_or(Value::Null);
                        let token = payload
                            .get("token")
                            .and_then(|x| x.as_str())
                            .ok_or_else(|| "auth.payload.token required".to_string())?;
                        let client_id = payload
                            .get("client_id")
                            .and_then(|x| x.as_str())
                            .map(|s| s.to_string());
                        return resolve_auth(db, token, client_id);
                    }
                    Some(Ok(Message::Ping(p))) => {
                        let mut s = sender.lock().await;
                        let _ = s.send(Message::Pong(p)).await;
                    }
                    Some(Ok(Message::Close(_))) | None => return Err("closed before auth".into()),
                    Some(Ok(_)) => continue,
                    Some(Err(_)) => return Err("socket error before auth".into()),
                }
            }
        }
    }
}

fn resolve_auth(db: &Db, token: &str, client_id: Option<String>) -> Result<AuthInfo, String> {
    let user = user_from_token(db, token).map_err(|_| "invalid or expired session".to_string())?;
    let family_id = family_id_for_user(db, user.id)?
        .ok_or_else(|| "join or create a family before connecting to /sync".to_string())?;
    Ok(AuthInfo {
        user_id: user.id,
        family_id,
        client_id: client_id.unwrap_or_else(|| Uuid::new_v4().to_string()),
    })
}

fn family_id_for_user(db: &Db, user_id: Uuid) -> Result<Option<Uuid>, String> {
    let conn = db.lock().map_err(|_| "db lock".to_string())?;
    let row: Option<String> = conn
        .query_row(
            "SELECT family_id FROM family_members WHERE user_id = ?1 LIMIT 1",
            params![user_id.to_string()],
            |r| r.get(0),
        )
        .optional_compat()
        .map_err(|_| "db query".to_string())?;
    Ok(row.and_then(|s| Uuid::parse_str(&s).ok()))
}

trait OptionalCompat<T> {
    fn optional_compat(self) -> rusqlite::Result<Option<T>>;
}

impl<T> OptionalCompat<T> for rusqlite::Result<T> {
    fn optional_compat(self) -> rusqlite::Result<Option<T>> {
        match self {
            Ok(v) => Ok(Some(v)),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
            Err(e) => Err(e),
        }
    }
}

async fn handle_client_text(
    hub: &SyncHub,
    family_id: Uuid,
    client_id: &str,
    text: &str,
) -> Result<(), String> {
    if text == "ping" || text.trim() == r#"{"type":"ping"}"# {
        let env = SyncEnvelope::new("pong", json!({})).with_client_id(Some(client_id.to_string()));
        hub.publish_to_family_async(family_id, env).await;
        return Ok(());
    }

    let v: Value =
        serde_json::from_str(text).map_err(|_| "client messages must be JSON".to_string())?;
    let msg_type = v.get("type").and_then(|x| x.as_str()).unwrap_or("");

    match msg_type {
        "ping" => {
            let env =
                SyncEnvelope::new("pong", json!({})).with_client_id(Some(client_id.to_string()));
            hub.publish_to_family_async(family_id, env).await;
        }
        "auth" => {
            // Already authenticated; ignore re-auth.
        }
        "refetch_state" => {
            // Client asks peers (and itself) to refresh home glance.
            let child_id = v
                .pointer("/payload/child_id")
                .cloned()
                .unwrap_or(Value::Null);
            let env = SyncEnvelope::new(
                "state",
                json!({ "child_id": child_id, "action": "refetch" }),
            )
            .with_client_id(Some(client_id.to_string()));
            hub.publish_to_family_async(family_id, env).await;
        }
        "" => return Err("missing type".into()),
        other => {
            tracing::debug!(msg_type = other, "ignored client ws message");
        }
    }
    Ok(())
}

/// Look up family_id for a child (used by HTTP handlers when broadcasting).
pub fn family_id_for_child(
    db: &Db,
    child_id: Uuid,
) -> Result<Option<Uuid>, crate::auth::AuthError> {
    let conn = db.lock().map_err(|_| crate::auth::AuthError::Internal)?;
    let row: Result<String, _> = conn.query_row(
        "SELECT family_id FROM children WHERE id = ?1",
        params![child_id.to_string()],
        |r| r.get(0),
    );
    match row {
        Ok(s) => Ok(Uuid::parse_str(&s).ok()),
        Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
        Err(_) => Err(crate::auth::AuthError::Internal),
    }
}

pub fn broadcast_event_upsert(
    hub: &SyncHub,
    db: &Db,
    event: &crate::models::Event,
    client_id: Option<String>,
) {
    if let Ok(Some(fid)) = family_id_for_child(db, event.child_id) {
        let payload = serde_json::to_value(event).unwrap_or(Value::Null);
        let env = SyncEnvelope::new("event.upsert", payload).with_client_id(client_id.clone());
        hub.publish_to_family(fid, env);
        let state = SyncEnvelope::new(
            "state",
            json!({ "child_id": event.child_id, "action": "refetch" }),
        )
        .with_client_id(client_id);
        hub.publish_to_family(fid, state);
    }
}

pub fn broadcast_event_delete(
    hub: &SyncHub,
    db: &Db,
    event_id: Uuid,
    child_id: Uuid,
    client_id: Option<String>,
) {
    if let Ok(Some(fid)) = family_id_for_child(db, child_id) {
        let env = SyncEnvelope::new(
            "event.delete",
            json!({ "id": event_id, "child_id": child_id }),
        )
        .with_client_id(client_id.clone());
        hub.publish_to_family(fid, env);
        let state = SyncEnvelope::new(
            "state",
            json!({ "child_id": child_id, "action": "refetch" }),
        )
        .with_client_id(client_id);
        hub.publish_to_family(fid, state);
    }
}

pub fn broadcast_timer_upsert(
    hub: &SyncHub,
    db: &Db,
    timer: &crate::models::Timer,
    client_id: Option<String>,
) {
    if let Ok(Some(fid)) = family_id_for_child(db, timer.child_id) {
        let payload = serde_json::to_value(timer).unwrap_or(Value::Null);
        let env = SyncEnvelope::new("timer.upsert", payload).with_client_id(client_id.clone());
        hub.publish_to_family(fid, env);
        let state = SyncEnvelope::new(
            "state",
            json!({ "child_id": timer.child_id, "action": "refetch" }),
        )
        .with_client_id(client_id);
        hub.publish_to_family(fid, state);
    }
}

pub fn broadcast_timer_stop(
    hub: &SyncHub,
    db: &Db,
    timer: &crate::models::Timer,
    client_id: Option<String>,
) {
    if let Ok(Some(fid)) = family_id_for_child(db, timer.child_id) {
        let payload = serde_json::to_value(timer).unwrap_or(Value::Null);
        let env = SyncEnvelope::new("timer.stop", payload).with_client_id(client_id.clone());
        hub.publish_to_family(fid, env);
        let state = SyncEnvelope::new(
            "state",
            json!({ "child_id": timer.child_id, "action": "refetch" }),
        )
        .with_client_id(client_id);
        hub.publish_to_family(fid, state);
    }
}
