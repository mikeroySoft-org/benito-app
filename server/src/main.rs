use std::path::{Path, PathBuf};

use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

/// Load KEY=VALUE pairs from a dotenv-style file into the process env.
/// Does not override variables that are already set. Ignores blank lines and `#` comments.
fn load_dotenv_file(path: &Path) {
    let Ok(text) = std::fs::read_to_string(path) else {
        return;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        if key.is_empty() {
            continue;
        }
        if std::env::var_os(key).is_some() {
            continue;
        }
        let value = value.trim().trim_matches('"').trim_matches('\'');
        std::env::set_var(key, value);
    }
}

fn resolve_session_secret() -> String {
    // Prefer explicit env / file after optional dotenv load.
    if let Ok(s) = std::env::var("SESSION_SECRET") {
        let s = s.trim().to_string();
        if !s.is_empty() {
            return s;
        }
    }
    if let Ok(path) = std::env::var("SESSION_SECRET_FILE") {
        if let Ok(s) = std::fs::read_to_string(&path) {
            let s = s.trim().to_string();
            if !s.is_empty() {
                return s;
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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // Load .env before tracing so RUST_LOG in the file applies when unset.
    for path in candidate_dotenv_paths() {
        if path.is_file() {
            load_dotenv_file(&path);
            break;
        }
    }

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "benito_server=info,tower_http=info".into()),
        )
        .with(tracing_subscriber::fmt::layer())
        .init();

    let database_path = std::env::var("DATABASE_PATH")
        .or_else(|_| std::env::var("DATABASE_URL"))
        .unwrap_or_else(|_| "data.db".into());
    let database_path = database_path
        .strip_prefix("sqlite:")
        .unwrap_or(&database_path)
        .to_string();

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

    let state = benito_server::app_state(&database_path, session_secret)?;
    let app = benito_server::build_router(state);

    let mut servers = tokio::task::JoinSet::new();
    for addr in &addrs {
        let listener = tokio::net::TcpListener::bind(addr).await?;
        tracing::info!("benito-server listening on http://{addr} (db={database_path})");
        let app = app.clone();
        servers.spawn(async move { axum::serve(listener, app).await });
    }

    // Keep the mDNS advertiser alive for as long as we serve.
    let _bonjour = benito_server::lan::lan_port(&addrs).and_then(|port| {
        let name = std::env::var("BENITO_BONJOUR_NAME").unwrap_or_else(|_| "Benito".into());
        benito_server::lan::advertise(port, &name)
    });

    if let Some(result) = servers.join_next().await {
        result??;
    }
    Ok(())
}
