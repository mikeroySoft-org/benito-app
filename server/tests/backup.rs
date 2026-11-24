//! Integration: built-in snapshots (while the database is open), retention, and restore.
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use benito_server::backup::{self, BackupService};
use benito_server::instance_lock::InstanceLock;

fn scratch_dir(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("benito-{tag}-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn add_user(state: &benito_server::AppState, name: &str) {
    let conn = state.db.lock().unwrap();
    conn.execute(
        "INSERT INTO users (id, name, email, password_hash, created_at) VALUES (?1,?2,?3,'x','2026-01-01T00:00:00+00:00')",
        rusqlite::params![uuid::Uuid::new_v4().to_string(), name, format!("{name}@example.com")],
    )
    .unwrap();
}

fn user_count(path: &Path) -> i64 {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.query_row("SELECT COUNT(*) FROM users", [], |r| r.get(0))
        .unwrap()
}

fn names_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

#[test]
fn snapshot_of_an_open_database_is_complete_private_and_pruned() {
    let dir = scratch_dir("backup");
    let db_path = dir.join("live.db");
    let backups = dir.join("backups");
    // Keeps its connection open in WAL mode for the whole test, like a running server.
    let state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    add_user(&state, "ana");

    let service = BackupService::new(db_path.clone(), backups.clone(), 2, 24);
    assert!(service.is_due(SystemTime::now()), "empty folder is due");

    let first = service.run().unwrap();
    assert_eq!(first.users, 1);
    assert_eq!(first.pruned, 0);
    assert_eq!(user_count(&first.snapshot.path), 1);
    assert!(
        !service.is_due(SystemTime::now()),
        "fresh snapshot is not due"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&first.snapshot.path)
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600, "snapshots hold a baby's health record");
    }

    // Files the service did not name are never pruned.
    std::fs::write(backups.join("data-20250101.db"), b"manual copy").unwrap();
    std::fs::write(backups.join("notes.txt"), b"keep me").unwrap();

    add_user(&state, "ben");
    let second = service.run().unwrap();
    add_user(&state, "cy");
    let third = service.run().unwrap();
    assert_eq!(third.users, 3, "rows still in the WAL are in the snapshot");
    assert_eq!(third.pruned, 1);

    assert_eq!(
        names_in(&backups),
        vec![
            second.snapshot.name.clone(),
            third.snapshot.name.clone(),
            "data-20250101.db".to_string(),
            "notes.txt".to_string(),
        ],
        "keeps the newest 2 snapshots, no temp or -wal/-shm litter, other files untouched"
    );
    let listed: Vec<String> = service
        .list()
        .unwrap()
        .into_iter()
        .map(|s| s.name)
        .collect();
    assert_eq!(listed, vec![third.snapshot.name, second.snapshot.name]);

    let on_demand_only = BackupService::new(db_path, dir.join("never"), 2, 0);
    assert!(!on_demand_only.is_due(SystemTime::now()));

    drop(state);
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn failed_snapshot_is_reported_and_leaves_nothing_behind() {
    let dir = scratch_dir("backup-missing");
    let backups = dir.join("backups");
    let service = BackupService::new(dir.join("absent.db"), backups.clone(), 2, 24);

    let err = service.run().unwrap_err();
    assert!(format!("{err:#}").contains("database not found"), "{err:#}");
    assert!(service.last_error().unwrap().contains("database not found"));
    assert!(
        !dir.join("absent.db").exists(),
        "must not create the database"
    );
    assert!(names_in(&backups).is_empty());

    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn restore_swaps_the_database_keeps_the_old_one_and_needs_the_lock() {
    let dir = scratch_dir("restore");
    let db_path = dir.join("live.db");
    let backups = dir.join("backups");

    let state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    add_user(&state, "ana");
    let snapshot = backup::create_snapshot(&db_path, &backups, 5)
        .unwrap()
        .snapshot
        .path;
    add_user(&state, "ben");
    drop(state);

    // A running server holds the lock; restore must not pull the file out from under it.
    let server = InstanceLock::acquire(&db_path).unwrap();
    let err = backup::restore(&db_path, &snapshot, Some(&backups)).unwrap_err();
    assert!(
        format!("{err:#}").contains("another benito-server"),
        "{err:#}"
    );
    assert_eq!(user_count(&db_path), 2, "refused restore changes nothing");
    drop(server);

    // Not a database at all: rejected before anything is replaced.
    let garbage = dir.join("garbage.db");
    std::fs::write(&garbage, b"this is not sqlite").unwrap();
    assert!(backup::restore(&db_path, &garbage, Some(&backups)).is_err());
    assert_eq!(user_count(&db_path), 2);

    let report = backup::restore(&db_path, &snapshot, Some(&backups)).unwrap();
    assert_eq!(report.users, 1);
    assert_eq!(
        user_count(&db_path),
        1,
        "database is the snapshot's contents"
    );
    let saved = report.pre_restore.expect("old database is kept");
    assert!(saved
        .file_name()
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with("pre-restore-"));
    assert_eq!(saved.parent().unwrap(), backups);
    assert_eq!(user_count(&saved), 2, "the replaced data is recoverable");
    assert_eq!(user_count(&snapshot), 1, "the snapshot itself is untouched");
    assert!(
        !names_in(&dir).iter().any(|n| n.contains("restore-tmp")),
        "no staging file left: {:?}",
        names_in(&dir)
    );

    // The restored file is a working server database (migrations ran, lock is free again).
    let state = benito_server::app_state(db_path.to_str().unwrap(), "test-secret").unwrap();
    add_user(&state, "dee");
    drop(state);
    assert!(InstanceLock::acquire(&db_path).is_ok());

    std::fs::remove_dir_all(dir).unwrap();
}
