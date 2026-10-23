#!/usr/bin/env bash
# Foreground debugging runner for benito-server on the home Mac, bound to loopback. Phones reach
# it over HTTPS via Tailscale Serve (see docs/deploy-tailscale.md), never plain HTTP on the LAN.
# The always-on setup is the launchd service (scripts/macos-service.sh, docs/deploy-macos.md);
# this script refuses to start while that service is installed so two servers never fight over
# the port and database. When the service's env file exists, its secret and database are used.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/server"

SERVICE_LABEL="com.mikeroysoft.benito.server"
if launchctl print "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1; then
  echo "The launchd service $SERVICE_LABEL is installed and already runs the server." >&2
  echo "To run in the foreground instead: scripts/macos-service.sh uninstall" >&2
  echo "  (or temporarily: launchctl bootout gui/$(id -u)/$SERVICE_LABEL)" >&2
  exit 1
fi

SERVICE_APP="$HOME/Library/Application Support/Benito"
if [[ -f "$SERVICE_APP/benito.env" ]]; then
  ENV_FILE="$SERVICE_APP/benito.env"
  DEFAULT_DB="$SERVICE_APP/benito.db"
else
  ENV_FILE="$ROOT/.env"
  DEFAULT_DB="$ROOT/server/data.db"
fi
export BENITO_ENV_FILE="$ENV_FILE"

export BIND_ADDR="${BIND_ADDR:-127.0.0.1:8080}"
export DATABASE_PATH="${DATABASE_PATH:-$DEFAULT_DB}"
export RUST_LOG="${RUST_LOG:-benito_server=info,tower_http=info}"

# Env file is gitignored / outside the repo. Binary also loads BENITO_ENV_FILE / SESSION_SECRET_FILE itself.
if [[ -z "${SESSION_SECRET:-}" ]]; then
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1091
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
fi
export SESSION_SECRET="${SESSION_SECRET:-dev-only-change-me}"

# MagicDNS name of this node (e.g. <machine>.<tailnet>.ts.net), if Tailscale is available.
# The macOS app ships its CLI inside the bundle and doesn't put it on PATH.
TS_CLI="$(command -v tailscale || true)"
if [[ -z "$TS_CLI" && -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
  TS_CLI=/Applications/Tailscale.app/Contents/MacOS/Tailscale
fi
TS_DNS=""
if [[ -n "$TS_CLI" ]] && command -v python3 >/dev/null 2>&1; then
  TS_DNS="$("$TS_CLI" status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' \
    2>/dev/null || true)"
fi

echo "benito-server starting"
echo "  BIND_ADDR=$BIND_ADDR"
echo "  ENV_FILE=$BENITO_ENV_FILE"
echo "  DATABASE_PATH=$DATABASE_PATH"
echo "  SESSION_SECRET: $([[ "$SESSION_SECRET" == "dev-only-change-me" ]] && echo DEFAULT || echo set/len=${#SESSION_SECRET})"
if [[ -n "$TS_DNS" ]]; then
  echo "  Server URL: https://$TS_DNS   (Tailscale Serve; set this in the app)"
else
  echo "  Server URL: unknown — Tailscale CLI missing, logged out, or MagicDNS off"
fi
echo "  One-time:   tailscale serve --bg --https=443 http://127.0.0.1:8080"
echo "  Health:     curl -sf http://127.0.0.1:8080/health"

BIN="$ROOT/server/target/release/benito-server"
if [[ -x "$BIN" && "${FORCE_CARGO_RUN:-}" != "1" ]]; then
  exec "$BIN"
fi
exec cargo run --release
