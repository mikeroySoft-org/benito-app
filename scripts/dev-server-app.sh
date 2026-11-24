#!/usr/bin/env bash
# Run Benito Server.app (apps/BenitoServer) against a scratch benito-server with demo data.
# Never touches the real install in ~/Library/Application Support/Benito.
#
#   scripts/dev-server-app.sh                 build both, start the server, launch the app
#   scripts/dev-server-app.sh --server-only   just the scratch server (poke the admin API by hand)
#   scripts/dev-server-app.sh --managed       launch the app with nothing installed, to try Install
#                                             Server, Start/Stop/Restart, Restore and Uninstall
#   scripts/dev-server-app.sh --reset         delete the scratch folder first
#
# The scratch folder is $BENITO_SERVER_HOME (default: $TMPDIR/benito-server-dev, or
# $TMPDIR/benito-server-managed with --managed) and survives between runs. The server binds
# loopback on free ports; invites point at http://127.0.0.1:<port>, which the iOS Simulator on
# this Mac can reach. Ctrl-C (or quitting the app) stops the server.
#
# With --managed the app installs a real LaunchAgent, but under a scratch label
# (com.mikeroysoft.benito.server.dev-<hash>) that can never be the family's service. This script
# unloads and removes every such agent when the app quits.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="${TMPDIR:-/tmp}"
managed=0
for arg in "$@"; do
  [[ "$arg" == "--managed" ]] && managed=1
done
if ((managed)); then
  SCRATCH="${BENITO_SERVER_HOME:-${TMP_ROOT%/}/benito-server-managed}"
else
  SCRATCH="${BENITO_SERVER_HOME:-${TMP_ROOT%/}/benito-server-dev}"
fi
SCRATCH="${SCRATCH%/}"
SERVER_BIN="$ROOT/server/target/debug/benito-server"
DERIVED="$ROOT/.derivedData/BenitoServer"
APP="$DERIVED/Build/Products/Debug/Benito Server.app"

die() {
  echo "error: $*" >&2
  exit 1
}

server_only=0
for arg in "$@"; do
  case "$arg" in
    --server-only) server_only=1 ;;
    --managed) ;;
    --reset)
      case "$SCRATCH" in
        "$HOME/Library/"*) die "refusing to delete $SCRATCH" ;;
      esac
      rm -rf "$SCRATCH"
      ;;
    *) die "unknown option: $arg" ;;
  esac
done

case "$SCRATCH" in
  "$HOME/Library/Application Support/Benito"*) die "BENITO_SERVER_HOME points at the real install" ;;
esac

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# Unloads and deletes the scratch LaunchAgents the app made in --managed mode. The glob needs the
# ".dev-" infix, so the real com.mikeroysoft.benito.server.plist cannot match.
remove_scratch_agents() {
  local plist label
  for plist in "$HOME/Library/LaunchAgents"/com.mikeroysoft.benito.server.dev-*.plist; do
    [[ -e "$plist" ]] || continue
    label="$(basename "$plist" .plist)"
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "    removed scratch agent $label"
  done
}

if ((managed)); then
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  echo "==> building Benito Server.app (embeds benito-server)"
  (cd "$ROOT/apps/BenitoServer" && xcodegen generate --quiet)
  xcodebuild build -quiet \
    -project "$ROOT/apps/BenitoServer/BenitoServer.xcodeproj" -scheme BenitoServer \
    -configuration Debug -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=
  mkdir -p "$SCRATCH"
  trap remove_scratch_agents EXIT
  echo "==> launching Benito Server with nothing installed"
  echo "    folder   $SCRATCH"
  echo "    Press Install Server in the window. Quit the app to remove the scratch service."
  open -W -n "$APP" --env BENITO_SERVER_HOME="$SCRATCH"
  exit 0
fi

echo "==> building benito-server"
(cd "$ROOT/server" && cargo build --locked)

if ((!server_only)); then
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  echo "==> building Benito Server.app"
  (cd "$ROOT/apps/BenitoServer" && xcodegen generate --quiet)
  xcodebuild build -quiet \
    -project "$ROOT/apps/BenitoServer/BenitoServer.xcodeproj" -scheme BenitoServer \
    -configuration Debug -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=
fi

mkdir -p "$SCRATCH/logs"
: >"$SCRATCH/empty.env"
fresh=0
[[ -f "$SCRATCH/benito.db" ]] || fresh=1
port="$(free_port)"
public_url="http://127.0.0.1:$port"

# BENITO_ENV_FILE points at an empty file so the repo's .env (real settings) is never loaded.
env \
  BENITO_ENV_FILE="$SCRATCH/empty.env" \
  DATABASE_PATH="$SCRATCH/benito.db" \
  BIND_ADDR="127.0.0.1:$port" \
  BENITO_PUBLIC_URLS="$public_url" \
  BENITO_ADMIN_ADDR="127.0.0.1:0" \
  BENITO_BACKUP_DIR="$SCRATCH/backups" \
  BENITO_BONJOUR=0 \
  SESSION_SECRET=dev-scratch-only \
  "$SERVER_BIN" >>"$SCRATCH/logs/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

for _ in $(seq 1 50); do
  curl -sf "$public_url/health" >/dev/null 2>&1 && break
  kill -0 "$server_pid" 2>/dev/null || die "server exited; see $SCRATCH/logs/server.log"
  sleep 0.1
done
curl -sf "$public_url/health" >/dev/null || die "server did not answer on $public_url"

if ((fresh)); then
  echo "==> seeding demo family"
  partner_key="$(openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null |
    openssl ec -pubout -outform DER 2>/dev/null | tail -c 65 | base64)"
  PUBLIC_URL="$public_url" ADMIN_FILE="$SCRATCH/admin.json" PARTNER_KEY="$partner_key" python3 - <<'PY'
import datetime as dt
import json
import os
import urllib.request

public = os.environ["PUBLIC_URL"]
with open(os.environ["ADMIN_FILE"]) as f:
    admin = json.load(f)


def call(base, method, path, body=None, token=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=10) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


def ago(**kw):
    return (dt.datetime.now(dt.timezone.utc) - dt.timedelta(**kw)).isoformat()


ana = call(public, "POST", "/auth/register",
           {"name": "Ana", "email": "ana@example.com", "password": "demo-password"})["token"]
call(public, "POST", "/families", {"name": "Demo Family", "child_name": "Benito"}, ana)
child = call(public, "GET", "/children", token=ana)[0]["id"]

events = [
    {"type": "medicine", "subtype": "Vitamin D", "started_at": ago(hours=6),
     "amount_value": 1, "amount_unit": "drops"},
    {"type": "feed_bottle", "subtype": "formula", "started_at": ago(hours=4),
     "ended_at": ago(hours=3, minutes=45), "amount_value": 3, "amount_unit": "oz"},
    {"type": "diaper", "subtype": "dirty", "started_at": ago(hours=3)},
    {"type": "feed_breast", "side": "L", "started_at": ago(hours=1, minutes=30),
     "ended_at": ago(hours=1, minutes=10)},
    {"type": "diaper", "subtype": "wet", "started_at": ago(minutes=35)},
]
for event in events:
    call(public, "POST", "/events", dict(event, child_id=child), ana)
call(public, "POST", "/timers", {"child_id": child, "kind": "sleep", "at": ago(minutes=25)}, ana)

# A partner who joined by invite (device key, no password), plus one invite still pending.
invite = call(admin["url"], "POST", "/admin/invites", {}, admin["token"])
call(public, "POST", "/invites/redeem", {
    "invite_id": invite["id"], "secret": invite["secret"], "name": "Ben",
    "public_key": os.environ["PARTNER_KEY"], "device_name": "Ben's iPhone", "model": "iPhone17,1",
})
call(admin["url"], "POST", "/admin/invites",
     {"role": "caregiver", "access_hours": 8, "label": "Saturday sitter"}, admin["token"])
PY
fi

echo "==> scratch server pid $server_pid"
echo "    public   $public_url"
echo "    folder   $SCRATCH"
echo "    log      $SCRATCH/logs/server.log"

if ((server_only)); then
  echo "    admin    see $SCRATCH/admin.json (url + token)"
  echo "Ctrl-C to stop."
  wait "$server_pid"
else
  echo "==> launching Benito Server (look for the icon in the menu bar; quit it to stop)"
  # Through LaunchServices, so it gets a menu bar item like a double-clicked app. -W waits for quit.
  open -W -n "$APP" --env BENITO_SERVER_HOME="$SCRATCH"
fi
