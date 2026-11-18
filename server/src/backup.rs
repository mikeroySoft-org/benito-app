//! Built-in database snapshots and restore.
//!
//! Snapshots use SQLite's online backup on a second, read-only connection, so they are
//! consistent while the server keeps writing in WAL mode. File names match
//! `scripts/backup-db.sh` (`benito-YYYYmmdd-HHMMSS.db`, local time), so both share one folder
//! and one retention count.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use anyhow::{bail, ensure, Context, Result};
use chrono::{DateTime, Local, Utc};
use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags};
use serde::Serialize;

use crate::instance_lock::InstanceLock;

pub const DEFAULT_KEEP: usize = 30;
pub const DEFAULT_INTERVAL_HOURS: u64 = 24;

const SNAPSHOT_PREFIX: &str = "benito-";
const SNAPSHOT_SUFFIX: &str = ".db";
/// How often the scheduler looks at the folder. Short, so a Mac that slept through the
/// interval catches up soon after it wakes.
const SCHEDULER_PERIOD: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Serialize)]
pub struct Snapshot {
    pub name: String,
    pub path: PathBuf,
    pub size_bytes: u64,
    pub modified_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct BackupReport {
    #[serde(flatten)]
    pub snapshot: Snapshot,
    pub users: i64,
    pub events: i64,
    pub pruned: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct RestoreReport {
    pub database: PathBuf,
    pub restored_from: PathBuf,
    /// Where the replaced database was saved; `None` when there was nothing to replace.
    pub pre_restore: Option<PathBuf>,
    pub users: i64,
    pub events: i64,
}

struct Counts {
    users: i64,
    events: i64,
}

pub struct BackupService {
    db_path: PathBuf,
    dir: PathBuf,
    keep: usize,
    interval_hours: u64,
    last_error: Mutex<Option<String>>,
    /// One snapshot at a time (scheduler and "back up now" can overlap).
    gate: Mutex<()>,
}

impl BackupService {
    pub fn new(db_path: PathBuf, dir: PathBuf, keep: usize, interval_hours: u64) -> Self {
        Self {
            db_path,
            dir,
            keep: keep.max(1),
            interval_hours,
            last_error: Mutex::new(None),
            gate: Mutex::new(()),
        }
    }

    /// `None` when `BENITO_BACKUP_DIR` is unset: built-in backups are opt-in.
    pub fn from_env(db_path: &Path) -> Result<Option<Self>> {
        let Some(dir) = std::env::var_os("BENITO_BACKUP_DIR").filter(|d| !d.is_empty()) else {
            return Ok(None);
        };
        let keep = match std::env::var("BENITO_BACKUP_KEEP") {
            Ok(raw) => raw
                .trim()
                .parse::<usize>()
                .ok()
                .filter(|k| *k >= 1)
                .with_context(|| {
                    format!("BENITO_BACKUP_KEEP must be a positive integer (got '{raw}')")
                })?,
            Err(_) => DEFAULT_KEEP,
        };
        let interval_hours = match std::env::var("BENITO_BACKUP_INTERVAL_HOURS") {
            Ok(raw) => raw.trim().parse::<u64>().with_context(|| {
                format!(
                    "BENITO_BACKUP_INTERVAL_HOURS must be a whole number of hours (got '{raw}')"
                )
            })?,
            Err(_) => DEFAULT_INTERVAL_HOURS,
        };
        Ok(Some(Self::new(
            db_path.to_path_buf(),
            PathBuf::from(dir),
            keep,
            interval_hours,
        )))
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    pub fn keep(&self) -> usize {
        self.keep
    }

    pub fn interval_hours(&self) -> u64 {
        self.interval_hours
    }

    /// Why the most recent snapshot attempt failed, if it did.
    pub fn last_error(&self) -> Option<String> {
        self.last_error.lock().ok().and_then(|e| e.clone())
    }

    /// Takes a snapshot now, then prunes. Blocking: call from `spawn_blocking` on the runtime.
    pub fn run(&self) -> Result<BackupReport> {
        let _gate = self.gate.lock().unwrap_or_else(|e| e.into_inner());
        let result = create_snapshot(&self.db_path, &self.dir, self.keep);
        if let Ok(mut slot) = self.last_error.lock() {
            *slot = result.as_ref().err().map(|e| format!("{e:#}"));
        }
        result
    }

    /// Snapshots in the folder, newest first. An absent folder is an empty list.
    pub fn list(&self) -> Result<Vec<Snapshot>> {
        list_snapshots(&self.dir)
    }

    pub fn is_due(&self, now: SystemTime) -> bool {
        if self.interval_hours == 0 {
            return false;
        }
        let interval = Duration::from_secs(self.interval_hours * 3600);
        match self.list().ok().and_then(|all| all.into_iter().next()) {
            Some(latest) => now
                .duration_since(SystemTime::from(latest.modified_at))
                .is_ok_and(|age| age >= interval),
            None => true,
        }
    }

    /// Snapshots whenever the newest one is older than the interval. Does nothing when the
    /// interval is 0 (on demand only).
    pub fn spawn_scheduler(self: Arc<Self>) -> Option<tokio::task::JoinHandle<()>> {
        if self.interval_hours == 0 {
            return None;
        }
        Some(tokio::spawn(async move {
            let mut tick = tokio::time::interval(SCHEDULER_PERIOD);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                if !self.is_due(SystemTime::now()) {
                    continue;
                }
                let service = self.clone();
                match tokio::task::spawn_blocking(move || service.run()).await {
                    Ok(Ok(report)) => tracing::info!(
                        file = %report.snapshot.path.display(),
                        size_bytes = report.snapshot.size_bytes,
                        users = report.users,
                        events = report.events,
                        pruned = report.pruned,
                        "backup ok"
                    ),
                    Ok(Err(e)) => tracing::error!("backup FAILED: {e:#}"),
                    Err(e) => tracing::error!("backup task failed: {e}"),
                }
            }
        }))
    }
}

fn sidecars(path: &Path) -> [PathBuf; 2] {
    ["-wal", "-shm"].map(|suffix| {
        let mut name = path.as_os_str().to_os_string();
        name.push(suffix);
        PathBuf::from(name)
    })
}

fn remove_sidecars(path: &Path) {
    for sidecar in sidecars(path) {
        let _ = std::fs::remove_file(sidecar);
    }
}

fn create_private_dir(dir: &Path) -> Result<()> {
    if dir.is_dir() {
        return Ok(());
    }
    let mut builder = std::fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder
        .create(dir)
        .with_context(|| format!("create {}", dir.display()))
}

/// Creates `path` empty and readable only by the owner; fails if it already exists.
fn create_private_file(path: &Path) -> Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options
        .open(path)
        .map(drop)
        .with_context(|| format!("create {}", path.display()))
}

/// Writes a consistent image of the database at `db_path` to the new file `dest`.
fn copy_database(db_path: &Path, dest: &Path) -> Result<()> {
    // Checked first: opening a missing path would otherwise report a confusing SQLite error.
    ensure!(
        db_path.is_file(),
        "database not found: {}",
        db_path.display()
    );
    let src = Connection::open_with_flags(
        db_path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("open {}", db_path.display()))?;
    src.busy_timeout(Duration::from_secs(5))?;
    create_private_file(dest)?;
    let mut dst = Connection::open(dest).with_context(|| format!("open {}", dest.display()))?;
    Backup::new(&src, &mut dst)?
        .run_to_completion(1024, Duration::from_millis(5), None)
        .with_context(|| format!("copy {} to {}", db_path.display(), dest.display()))?;
    Ok(())
}

fn row_counts(conn: &Connection) -> Result<Counts> {
    let count = |table: &str| -> Result<i64> {
        conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
            .with_context(|| format!("not a Benito database (no {table} table)"))
    };
    Ok(Counts {
        users: count("users")?,
        events: count("events")?,
    })
}

/// Integrity check plus the row counts that show up in logs and reports.
fn verify(path: &Path) -> Result<Counts> {
    let result = (|| {
        let conn = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| format!("open {}", path.display()))?;
        let check: String = conn
            .query_row("PRAGMA integrity_check", [], |r| r.get(0))
            .context("integrity_check could not run")?;
        ensure!(check == "ok", "integrity_check: {check}");
        row_counts(&conn)
    })();
    // A WAL-mode image opens with -wal/-shm beside it; nothing was written, so they are empty.
    remove_sidecars(path);
    result
}

fn snapshot_of(path: PathBuf) -> Option<Snapshot> {
    let name = path.file_name()?.to_str()?.to_string();
    let meta = std::fs::metadata(&path).ok()?;
    Some(Snapshot {
        name,
        size_bytes: meta.len(),
        modified_at: meta.modified().ok()?.into(),
        path,
    })
}

fn list_snapshots(dir: &Path) -> Result<Vec<Snapshot>> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e).with_context(|| format!("read {}", dir.display())),
    };
    let mut snapshots: Vec<Snapshot> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(SNAPSHOT_PREFIX) && n.ends_with(SNAPSHOT_SUFFIX))
        })
        .filter_map(snapshot_of)
        .collect();
    // Timestamped names sort chronologically.
    snapshots.sort_by(|a, b| b.name.cmp(&a.name));
    Ok(snapshots)
}

/// A free path in `dir` named `<stem>-<timestamp>.db`. Names are the sort order for
/// retention, so a name already taken this second is waited out rather than suffixed.
fn timestamped_path(dir: &Path, stem: &str) -> PathBuf {
    loop {
        let stamp = Local::now().format("%Y%m%d-%H%M%S");
        let path = dir.join(format!("{stem}-{stamp}.db"));
        if !path.exists() {
            return path;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// One snapshot of `db_path` into `dir`, verified before it gets its final name, then the
/// oldest `benito-*.db` files beyond `keep` are removed. Other files are left alone.
pub fn create_snapshot(db_path: &Path, dir: &Path, keep: usize) -> Result<BackupReport> {
    create_private_dir(dir)?;
    // Same folder as the final file, so the rename is atomic.
    let tmp = dir.join(format!(".benito-backup.{}.tmp", std::process::id()));
    let _ = std::fs::remove_file(&tmp);
    let counts = copy_database(db_path, &tmp).and_then(|()| verify(&tmp));
    let counts = match counts {
        Ok(counts) => counts,
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            remove_sidecars(&tmp);
            return Err(e);
        }
    };
    let dest = timestamped_path(dir, SNAPSHOT_PREFIX.trim_end_matches('-'));
    std::fs::rename(&tmp, &dest).with_context(|| format!("rename to {}", dest.display()))?;

    let mut pruned = 0;
    for old in list_snapshots(dir)?.into_iter().skip(keep.max(1)) {
        if std::fs::remove_file(&old.path).is_ok() {
            pruned += 1;
        }
    }
    let snapshot = snapshot_of(dest.clone())
        .with_context(|| format!("snapshot vanished: {}", dest.display()))?;
    Ok(BackupReport {
        snapshot,
        users: counts.users,
        events: counts.events,
        pruned,
    })
}

/// Saves the database that is about to be replaced. A damaged file cannot go through the
/// backup API, so that case falls back to copying the raw files.
fn save_current(db_path: &Path, dir: &Path) -> Result<PathBuf> {
    create_private_dir(dir)?;
    let dest = timestamped_path(dir, "pre-restore");
    if copy_database(db_path, &dest).is_ok() {
        remove_sidecars(&dest);
        return Ok(dest);
    }
    let _ = std::fs::remove_file(&dest);
    std::fs::copy(db_path, &dest)
        .with_context(|| format!("copy {} to {}", db_path.display(), dest.display()))?;
    for (from, to) in sidecars(db_path).iter().zip(sidecars(&dest)) {
        if from.exists() {
            std::fs::copy(from, &to).with_context(|| format!("copy {}", from.display()))?;
        }
    }
    Ok(dest)
}

/// Replaces the database at `db_path` with `snapshot`. Refuses while a server holds the
/// instance lock. The replaced database is kept as `pre-restore-<timestamp>.db` in
/// `safety_dir` (or next to the database).
pub fn restore(
    db_path: &Path,
    snapshot: &Path,
    safety_dir: Option<&Path>,
) -> Result<RestoreReport> {
    ensure!(
        snapshot.is_file(),
        "snapshot not found: {}",
        snapshot.display()
    );
    let _lock = InstanceLock::acquire(db_path)?;
    let db_dir = db_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(db_dir).with_context(|| format!("create {}", db_dir.display()))?;

    // Work on a copy beside the database: the snapshot stays untouched and the final rename
    // is atomic.
    let mut staged = db_path.as_os_str().to_os_string();
    staged.push(".restore-tmp");
    let staged = PathBuf::from(staged);
    let _ = std::fs::remove_file(&staged);
    remove_sidecars(&staged);
    std::fs::copy(snapshot, &staged)
        .with_context(|| format!("copy {} to {}", snapshot.display(), staged.display()))?;
    if let Err(e) = verify(&staged) {
        let _ = std::fs::remove_file(&staged);
        bail!("{} is not usable: {e:#}", snapshot.display());
    }

    let pre_restore = if db_path.exists() {
        match save_current(db_path, safety_dir.unwrap_or(db_dir)) {
            Ok(saved) => Some(saved),
            Err(e) => {
                let _ = std::fs::remove_file(&staged);
                return Err(e.context("could not save the current database; nothing was changed"));
            }
        }
    } else {
        None
    };

    // Stale -wal/-shm from the old database must not be replayed onto the new one.
    remove_sidecars(db_path);
    std::fs::rename(&staged, db_path)
        .with_context(|| format!("rename to {}", db_path.display()))?;

    // An older snapshot may predate the current schema; opening it runs the migrations.
    let db_str = db_path
        .to_str()
        .with_context(|| format!("database path is not UTF-8: {}", db_path.display()))?;
    let db = crate::db::open(db_str)?;
    let counts = {
        let conn = db.lock().unwrap_or_else(|e| e.into_inner());
        row_counts(&conn)?
    };
    Ok(RestoreReport {
        database: db_path.to_path_buf(),
        restored_from: snapshot.to_path_buf(),
        pre_restore,
        users: counts.users,
        events: counts.events,
    })
}
