use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Family {
    pub id: Uuid,
    pub name: String,
    pub invite_code: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Child {
    pub id: Uuid,
    pub family_id: Uuid,
    pub name: String,
    pub birthdate: Option<String>,
    pub sex: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: Uuid,
    pub child_id: Uuid,
    pub r#type: String,
    pub subtype: Option<String>,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub amount_value: Option<f64>,
    pub amount_unit: Option<String>,
    pub side: Option<String>,
    pub notes: Option<String>,
    pub payload_json: Option<serde_json::Value>,
    pub created_by: Uuid,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub deleted_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Timer {
    pub id: Uuid,
    pub child_id: Uuid,
    pub kind: String,
    pub started_at: DateTime<Utc>,
    pub started_by: Uuid,
    pub state: String,
    pub stopped_at: Option<DateTime<Utc>>,
    pub updated_at: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub side: Option<String>,
    /// Start of the pause in progress; set only while `state == "paused"`.
    #[serde(default)]
    pub paused_at: Option<DateTime<Utc>>,
    /// Seconds of completed pauses (excludes the open pause, which is `now - paused_at`).
    #[serde(default)]
    pub paused_seconds: i64,
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    pub name: String,
    pub email: String,
    pub password: String,
}

#[derive(Debug, Deserialize)]
pub struct LoginRequest {
    pub email: String,
    pub password: String,
}

#[derive(Debug, Serialize)]
pub struct AuthResponse {
    pub token: String,
    pub user: User,
}

#[derive(Debug, Deserialize)]
pub struct CreateFamilyRequest {
    pub name: String,
    pub child_name: String,
    pub child_birthdate: Option<String>,
    pub child_sex: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct CreateFamilyResponse {
    pub family: Family,
    pub child: Child,
    pub invite_code: String,
}

#[derive(Debug, Deserialize)]
pub struct JoinFamilyRequest {
    pub invite_code: String,
}

/// `POST /families/pairing-tokens`: a short-lived, single-use token for proximity pairing.
#[derive(Debug, Serialize)]
pub struct CreatePairingTokenResponse {
    pub token: String,
    pub family_name: String,
    pub expires_at: DateTime<Utc>,
}

/// `POST /families/pair`: redeem a pairing token to join its family.
#[derive(Debug, Deserialize)]
pub struct PairWithTokenRequest {
    pub token: String,
}

#[derive(Debug, Deserialize)]
pub struct CreateEventRequest {
    pub child_id: Uuid,
    pub r#type: String,
    pub subtype: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    pub amount_value: Option<f64>,
    pub amount_unit: Option<String>,
    pub side: Option<String>,
    pub notes: Option<String>,
    pub payload_json: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateEventRequest {
    pub subtype: Option<String>,
    pub started_at: Option<DateTime<Utc>>,
    pub ended_at: Option<DateTime<Utc>>,
    pub amount_value: Option<f64>,
    pub amount_unit: Option<String>,
    pub side: Option<String>,
    pub notes: Option<String>,
    pub payload_json: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
pub struct StartTimerRequest {
    pub child_id: Uuid,
    pub kind: String,
    /// Optional breast side (`L` / `R`) when kind is `feed_breast`.
    pub side: Option<String>,
    /// Phone wall clock for `started_at`. When set, the server stores this instead of
    /// `Utc::now()` so device `Date()` / TimelineView elapsed starts near 0:00.
    /// Multi-device sync assumes phones are roughly NTP-aligned.
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
}

/// Optional phone wall clock on pause / resume / stop (`{}` keeps server `Utc::now()`).
#[derive(Debug, Deserialize, Default)]
pub struct TimerAtRequest {
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
}

/// `PATCH /timers/{id}`: move an active timer's start ("forgot to start it 10 minutes ago").
#[derive(Debug, Deserialize)]
pub struct AdjustTimerRequest {
    pub started_at: DateTime<Utc>,
    /// Phone wall clock used as "now" when checking future / 24h bounds.
    /// Omitted → server `Utc::now()` (older clients and tests).
    #[serde(default)]
    pub at: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize)]
pub struct BabyState {
    pub child_id: Uuid,
    pub last_feed: Option<Event>,
    pub last_diaper: Option<Event>,
    pub active_timer: Option<Timer>,
    pub last_medicine: Option<Event>,
}

#[derive(Debug, Serialize)]
pub struct ExportBundle {
    pub exported_at: DateTime<Utc>,
    pub family: Option<Family>,
    pub children: Vec<Child>,
    pub events: Vec<Event>,
    pub timers: Vec<Timer>,
}

#[derive(Debug, Deserialize)]
pub struct CreateChildRequest {
    pub name: String,
    pub birthdate: Option<String>,
    pub sex: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct MeResponse {
    pub user: User,
    pub family: Option<Family>,
    pub children: Vec<Child>,
    /// `parent` | `caregiver`; absent without a family. Older apps ignore these fields.
    pub role: Option<String>,
    /// Caregiver access end (RFC 3339), if any.
    pub access_expires_at: Option<String>,
    /// Whether this account has a registered device key (passwordless re-auth available).
    pub has_device_key: bool,
}
