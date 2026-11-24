//! One process per database. `serve` holds the lock for its lifetime; `restore` takes it to
//! prove no server has the file open before replacing it.

use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

/// Advisory lock on `<database>.lock`, released when dropped or when the process dies.
#[derive(Debug)]
pub struct InstanceLock {
    _file: File,
}

pub fn lock_path(db_path: &Path) -> PathBuf {
    let mut name = db_path.as_os_str().to_os_string();
    name.push(".lock");
    PathBuf::from(name)
}

impl InstanceLock {
    pub fn acquire(db_path: &Path) -> Result<Self> {
        let path = lock_path(db_path);
        if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create {}", parent.display()))?;
        }
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .with_context(|| format!("open {}", path.display()))?;
        if !try_lock(&file) {
            bail!(
                "another benito-server is using {} (stop it first)",
                db_path.display()
            );
        }
        Ok(Self { _file: file })
    }
}

#[cfg(unix)]
fn try_lock(file: &File) -> bool {
    use std::os::fd::AsRawFd;
    // SAFETY: `file` owns a valid descriptor for the duration of the call.
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

#[cfg(not(unix))]
fn try_lock(_file: &File) -> bool {
    true
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn second_holder_is_refused_until_the_first_lets_go() {
        let dir = std::env::temp_dir().join(format!("benito-lock-{}", uuid::Uuid::new_v4()));
        let db = dir.join("test.db");
        let first = InstanceLock::acquire(&db).unwrap();
        assert!(InstanceLock::acquire(&db).is_err());
        drop(first);
        assert!(InstanceLock::acquire(&db).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
