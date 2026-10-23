//! LAN reachability: multiple listen addresses and Bonjour (`_benito._tcp`) advertising, so a
//! phone on the home Wi-Fi (a babysitter, say) can find and reach the server without Tailscale.

use std::net::SocketAddr;

pub const BONJOUR_SERVICE_TYPE: &str = "_benito._tcp";

/// Parses `BIND_ADDR`, which may list several addresses: `127.0.0.1:8080,0.0.0.0:8081`.
pub fn parse_bind_addrs(raw: &str) -> Result<Vec<SocketAddr>, std::net::AddrParseError> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::parse)
        .collect()
}

/// The first listener reachable from other machines (unspecified or non-loopback).
pub fn lan_port(addrs: &[SocketAddr]) -> Option<u16> {
    addrs
        .iter()
        .find(|a| !a.ip().is_loopback())
        .map(|a| a.port())
}

/// Advertises the service with the OS mDNS responder. Returns the child process (kept alive
/// for the server's lifetime; `kill_on_drop`). Disabled with `BENITO_BONJOUR=0`.
pub fn advertise(port: u16, name: &str) -> Option<tokio::process::Child> {
    if std::env::var("BENITO_BONJOUR")
        .map(|v| v == "0")
        .unwrap_or(false)
    {
        return None;
    }
    let txt = format!("version={}", env!("CARGO_PKG_VERSION"));
    let port_s = port.to_string();
    let (program, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") {
        (
            "/usr/bin/dns-sd",
            vec!["-R", name, BONJOUR_SERVICE_TYPE, "local", &port_s, &txt],
        )
    } else {
        (
            "avahi-publish",
            vec!["-s", name, BONJOUR_SERVICE_TYPE, &port_s, &txt],
        )
    };
    match tokio::process::Command::new(program)
        .args(&args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => {
            tracing::info!("Bonjour: advertising \"{name}\" {BONJOUR_SERVICE_TYPE} on port {port}");
            Some(child)
        }
        Err(e) => {
            tracing::warn!("Bonjour advertising unavailable ({program}: {e})");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_and_multiple_bind_addrs() {
        assert_eq!(parse_bind_addrs("127.0.0.1:8080").unwrap().len(), 1);
        let addrs = parse_bind_addrs("127.0.0.1:8080, 0.0.0.0:8081").unwrap();
        assert_eq!(addrs.len(), 2);
        assert_eq!(lan_port(&addrs), Some(8081));
        assert_eq!(lan_port(&parse_bind_addrs("127.0.0.1:8080").unwrap()), None);
        assert!(parse_bind_addrs("nope").is_err());
    }
}
