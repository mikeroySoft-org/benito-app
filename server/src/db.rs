use anyhow::{Context, Result};
use rusqlite::Connection;
use std::path::Path;
use std::sync::{Arc, Mutex};

pub type Db = Arc<Mutex<Connection>>;

pub fn open(path: &str) -> Result<Db> {
    if let Some(parent) = Path::new(path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create db dir {}", parent.display()))?;
        }
    }
    let conn = Connection::open(path).with_context(|| format!("open sqlite {}", path))?;
    conn.execute_batch("PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL;")?;
    migrate(&conn)?;
    Ok(Arc::new(Mutex::new(conn)))
}

fn has_column(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let found = conn
        .prepare(&format!("PRAGMA table_info({table})"))?
        .query_map([], |row| row.get::<_, String>(1))?
        .filter_map(|r| r.ok())
        .any(|name| name == column);
    Ok(found)
}

fn migrate(conn: &Connection) -> Result<()> {
    conn.execute_batch(include_str!("../migrations/001_init.sql"))?;
    // 002: add timers.side if missing (SQLite has no IF NOT EXISTS for columns).
    if !has_column(conn, "timers", "side")? {
        conn.execute_batch(include_str!("../migrations/002_timer_side.sql"))?;
    }
    // 003: timers.paused_at + timers.paused_seconds (applied together in one transaction).
    if !has_column(conn, "timers", "paused_seconds")? {
        conn.execute_batch(include_str!("../migrations/003_timer_pause.sql"))?;
    }
    // 004: pairing_tokens table (idempotent CREATE ... IF NOT EXISTS).
    conn.execute_batch(include_str!("../migrations/004_pairing_tokens.sql"))?;
    // 005: ActivityKit Live Activity update push tokens.
    conn.execute_batch(include_str!("../migrations/005_live_activity_tokens.sql"))?;
    // 006: devices, family_invites, server_meta (idempotent CREATE ... IF NOT EXISTS).
    conn.execute_batch(include_str!("../migrations/006_devices_invites.sql"))?;
    // 006b: nullable columns; older server builds ignore them, so rollback stays safe.
    if !has_column(conn, "family_members", "expires_at")? {
        conn.execute_batch("ALTER TABLE family_members ADD COLUMN expires_at TEXT;")?;
    }
    if !has_column(conn, "sessions", "device_id")? {
        conn.execute_batch("ALTER TABLE sessions ADD COLUMN device_id TEXT;")?;
    }
    conn.execute(
        "INSERT OR IGNORE INTO server_meta (key, value) VALUES ('server_id', ?1)",
        [uuid::Uuid::new_v4().to_string()],
    )?;
    Ok(())
}
