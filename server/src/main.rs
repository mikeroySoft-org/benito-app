use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{ensure, Context};
use benito_server::admin::{self, Handoff};
use benito_server::backup::{self, BackupService};
use benito_server::instance_lock::InstanceLock;
use benito_server::ServerInfo;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

const USAGE: &str = "\
usage: benito-server [command]

  (no command)       run the server
  backup             write one snapshot to BENITO_BACKUP_DIR (safe while a server runs)
  restore <file>     replace the database with a snapshot (the server must be stopped)
  --version          print the version

Settings come from the environment or a dotenv file; see server/README.md.";

/// How long open requests and WebSockets get to finish after SIGTERM / Ctrl-C.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// Load KEY=VALUE pairs from a dotenv-style file into the process env.
/// Does not override variables that are already set. Ignores blank lines and `#` comments.
fn load_dotenv_file(path: &Path) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    for (key, value) in benito_server::envfile::parse_dotenv(&text) {
        if std::env::var_os(&key).is_some() {
            continue;
        }
        std::env::set_var(key, value);
    }
}

fn resolve_session_secret() -> String {
    // Prefer explicit env / file after optional dotenv load.
    let env_value = std::env::var("SESSION_SECRET").ok();
    if let Some(secret) = benito_server::envfile::pick_session_secret(env_value.as_deref(), None) {
        return secret;
    }
    if let Ok(path) = std::env::var("SESSION_SECRET_FILE") {
        if let Ok(s) = std::fs::read_to_string(&path) {
            if let Some(secret) = benito_server::envfile::pick_session_secret(None, Some(&s)) {
                return secret;
            }
        } else {
            tracing::warn!("SESSION_SECRET_FILE set but unreadable: {path}");
        }
    }
    "dev-only-change-me".into()
}

fn candidate_dotenv_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Ok(p) = std::env::var("BENITO_ENV_FILE") {
        paths.push(PathBuf::from(p));
    }
    // CWD (usually server/ when cargo run) and parent (repo root).
    paths.push(PathBuf::from(".env"));
    paths.push(PathBuf::from("../.env"));
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            paths.push(dir.join(".env"));
            paths.push(dir.join("../.env"));
            paths.push(dir.join("../../.env"));
        }
    }
    paths
}

fn database_path() -> String {
    let database_path = std::env::var("DATABASE_PATH")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap_or_else(|_| "data.db".into());
    database_path
        .strip_prefix("sqlite:")
        .unwrap_or(&database_path)
        .to_string()
}

fn env_path(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let terminate = async {
        use tokio::signal::unix::{signal, SignalKind};
        match signal(SignalKind::terminate()) {
            Ok(mut stream) => {
                stream.recv().await;
            }
            Err(_) => std::future::pending::<()>().await,
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        _ = ctrl_c => {}
        _ = terminate => {}
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    match args.as_slice() {
        ["--version"] | ["-V"] => {
            println!("benito-server {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        ["--help"] | ["-h"] => {
            println!("{USAGE}");
            return Ok(());
        }
        [] | ["backup"] | ["restore", _] => {}
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }

    // Load .env before tracing so RUST_LOG in the file applies when unset.
    for path in candidate_dotenv_paths() {
        if path.is_file() {
            load_dotenv_file(&path);
            break;
        }
    }

    match args.as_slice() {
        ["backup"] => backup_command(),
        ["restore", file] => restore_command(Path::new(file)),
        _ => serve().await,
    }
}

fn backup_command() -> anyhow::Result<()> {
    let database_path = database_path();
    let service = BackupService::from_env(Path::new(&database_path))?
        .context("BENITO_BACKUP_DIR is not set")?;
    let report = service.run()?;
    println!("{}", serde_json::to_string(&report)?);
    Ok(())
}

fn restore_command(snapshot: &Path) -> anyhow::Result<()> {
    let database_path = database_path();
    let report = backup::restore(
        Path::new(&database_path),
        snapshot,
        env_path("BENITO_BACKUP_DIR").as_deref(),
    )?;
    println!("{}", serde_json::to_string(&report)?);
    Ok(())
}

async fn serve() -> anyhow::Result<()> {
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "benito_server=info,tower_http=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let database_path = database_path();

    let session_secret = resolve_session_secret();
    if session_secret == "dev-only-change-me" {
        tracing::warn!(
            "SESSION_SECRET is default; set via env, .env, or SESSION_SECRET_FILE for any real deploy"
        );
    } else {
        tracing::info!(
            "SESSION_SECRET loaded (len={}; sessions are DB tokens — rotate does not invalidate them)",
            session_secret.len()
        );
    }

    // BIND_ADDR may list several listeners, e.g. loopback for Tailscale Serve plus a LAN port.
    let bind = std::env::var("BIND_ADDR").unwrap_or_else(|_| "127.0.0.1:8080".into());
    let addrs = benito_server::lan::parse_bind_addrs(&bind)?;
    anyhow::ensure!(!addrs.is_empty(), "BIND_ADDR is empty");

    // Held until exit: one server per database file.
    let _lock = InstanceLock::acquire(Path::new(&database_path))?;
    let mut state = benito_server::app_state(&database_path, session_secret)?;
    let db = state.db.clone();
    let started_at = state.info.started_at;

    let mut listeners = Vec::with_capacity(addrs.len());
    for addr in &addrs {
        listeners.push(tokio::net::TcpListener::bind(addr).await?);
    }

    // Keep the mDNS advertiser alive for as long as we serve.
    let bonjour_name = std::env::var("BENITO_BONJOUR_NAME").unwrap_or_else(|_| "Benito".into());
    let bonjour = benito_server::lan::lan_port(&addrs)
        .and_then(|port| benito_server::lan::advertise(port, &bonjour_name));

    let backups = BackupService::from_env(Path::new(&database_path))?.map(Arc::new);
    state.info = Arc::new(ServerInfo {
        db_path: PathBuf::from(&database_path),
        started_at,
        listeners: addrs.clone(),
        bonjour_name: bonjour.is_some().then_some(bonjour_name),
    });
    state.backups = backups.clone();

    let (stop_tx, stop_rx) = tokio::sync::watch::channel(false);
    let stopped = |mut rx: tokio::sync::watch::Receiver<bool>| async move {
        let _ = rx.wait_for(|stop| *stop).await;
    };

    let mut servers = tokio::task::JoinSet::new();

    // Local admin API for the Mac server app: its own loopback port, never a public listener.
    let handoff = match std::env::var("BENITO_ADMIN_ADDR") {
        Ok(raw) if !raw.trim().is_empty() => {
            let addr: SocketAddr = raw
                .trim()
                .parse()
                .with_context(|| format!("BENITO_ADMIN_ADDR is not an address: {raw}"))?;
            ensure!(
                addr.ip().is_loopback(),
                "BENITO_ADMIN_ADDR must be a loopback address (got {addr})"
            );
            let listener = tokio::net::TcpListener::bind(addr)
                .await
                .with_context(|| format!("bind admin listener {addr}"))?;
            let bound = listener.local_addr()?;
            let token = benito_server::auth::new_session_token();
            let path = env_path("BENITO_ADMIN_FILE")
                .unwrap_or_else(|| admin::default_handoff_path(Path::new(&database_path)));
            let handoff = Handoff::write(&path, bound, &token, started_at)?;
            tracing::info!(
                "admin API on http://{bound} (handoff file {})",
                path.display()
            );
            let app = admin::router(state.clone(), &token);
            let stop = stopped(stop_rx.clone());
            servers.spawn(async move {
                axum::serve(listener, app)
                    .with_graceful_shutdown(stop)
                    .await
            });
            Some(handoff)
        }
        _ => None,
    };

    let app = benito_server::build_router(state);
    for listener in listeners {
        tracing::info!(
            "benito-server listening on http://{} (db={database_path})",
            listener.local_addr()?
        );
        let app = app.clone();
        let stop = stopped(stop_rx.clone());
        servers.spawn(async move {
            axum::serve(listener, app)
                .with_graceful_shutdown(stop)
                .await
        });
    }

    let scheduler = backups.and_then(|service| {
        tracing::info!(
            "backups: {} (keep {}, every {} h)",
            service.dir().display(),
            service.keep(),
            service.interval_hours()
        );
        service.spawn_scheduler()
    });

    let outcome = tokio::select! {
        Some(result) = servers.join_next() => result
            .map_err(anyhow::Error::from)
            .and_then(|served| served.map_err(anyhow::Error::from)),
        _ = shutdown_signal() => {
            tracing::info!("shutting down");
            let _ = stop_tx.send(true);
            let drain = async { while servers.join_next().await.is_some() {} };
            if tokio::time::timeout(SHUTDOWN_GRACE, drain).await.is_err() {
                tracing::warn!("connections still open after {SHUTDOWN_GRACE:?}; closing them");
                servers.shutdown().await;
            }
            Ok(())
        }
    };

    if let Some(scheduler) = scheduler {
        scheduler.abort();
    }
    // Fold the WAL back into the main file so a stopped server leaves one complete file.
    if let Ok(conn) = db.lock() {
        if let Err(e) = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);") {
            tracing::warn!("WAL checkpoint on shutdown failed: {e}");
        }
    }
    drop(handoff);
    tracing::info!("stopped");
    outcome
}
