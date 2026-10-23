#!/usr/bin/env bash
# Run benito-server as an always-on macOS service (launchd) with nightly SQLite backups.
# See docs/deploy-macos.md.
#
#   scripts/macos-service.sh install|uninstall|restart|status|logs|backup-now
#
# LaunchAgent, not LaunchDaemon: agents run in the user's login session, which auto-login brings
# back after a reboot. The Tailscale GUI app that fronts the server with Serve HTTPS needs that
# same session, so a system daemon would gain nothing while requiring sudo and root-owned files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SERVER_LABEL="com.mikeroysoft.benito.server"
BACKUP_LABEL="com.mikeroysoft.benito.backup"
APP="$HOME/Library/Application Support/Benito"
BIN_DIR="$APP/bin"
SERVER_BIN="$BIN_DIR/benito-server"
BACKUP_SCRIPT="$BIN_DIR/backup-db.sh"
ENV_FILE="$APP/benito.env"
DB="$APP/benito.db"
LOG_DIR="$HOME/Library/Logs/Benito"
SERVER_LOG="$LOG_DIR/server.log"
BACKUP_LOG="$LOG_DIR/backup.log"
BACKUP_DIR="$HOME/Backups/benito"
AGENTS_DIR="$HOME/Library/LaunchAgents"
SERVER_PLIST="$AGENTS_DIR/$SERVER_LABEL.plist"
BACKUP_PLIST="$AGENTS_DIR/$BACKUP_LABEL.plist"
LEGACY_DB="${LEGACY_DB:-$ROOT/server/data.db}"
SERVICE_PORT=8080
SERVICE_BIND="127.0.0.1:$SERVICE_PORT"
HEALTH_URL="http://$SERVICE_BIND/health"
DOMAIN="gui/$(id -u)"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found on PATH"
  done
}

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") <command>

  install     build, install and (re)start the server + nightly backup LaunchAgents
  uninstall   stop and remove both LaunchAgents (keeps DB, env, backups, logs)
  restart     restart the server and wait for /health
  status      launchd state, health, database size, newest backup
  logs        follow the server log
  backup-now  run the backup agent immediately
EOF
}

is_loaded() {
  launchctl print "$DOMAIN/$1" >/dev/null 2>&1
}

port_in_use() {
  lsof -nP -iTCP:"$SERVICE_PORT" -sTCP:LISTEN >/dev/null 2>&1
}

# bootout returns before launchd has fully torn the job down; bootstrap fails until it has.
unload() {
  local label=$1 i
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  for ((i = 0; i < 100; i++)); do
    is_loaded "$label" || return 0
    sleep 0.1
  done
  die "launchd did not unload $label"
}

health_wait() {
  local i
  for ((i = 0; i < 15; i++)); do
    if curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      echo "healthy: $HEALTH_URL"
      return 0
    fi
    sleep 1
  done
  echo "error: server not healthy after 15s; see $SERVER_LOG" >&2
  return 1
}

# Copy to a temp name, then rename: a running process keeps its old inode, and macOS never sees
# a half-written (or in-place modified, signature-invalid) executable.
install_file() {
  local src=$1 dest=$2 tmp="$2.tmp.$$"
  cp "$src" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$dest"
}

set_env_key() {
  local key=$1 value=$2 tmp
  tmp="$(mktemp "$ENV_FILE.XXXXXX")"
  grep -Ev "^[[:space:]]*$key[[:space:]]*=" "$ENV_FILE" >"$tmp" || true
  printf '%s="%s"\n' "$key" "$value" >>"$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

write_env_file() {
  local tmp
  if [[ -f "$ENV_FILE" ]]; then
    echo "env:      $ENV_FILE (existing, preserved)"
  else
    tmp="$(mktemp "$ENV_FILE.XXXXXX")" # mktemp creates mode 600
    {
      echo "# benito-server environment for the launchd service (scripts/macos-service.sh)."
      echo "# BIND_ADDR and DATABASE_PATH are rewritten on every install."
      if [[ -f "$ROOT/.env" ]]; then
        grep -E '^[[:space:]]*(SESSION_SECRET|SESSION_SECRET_FILE|RUST_LOG)[[:space:]]*=' "$ROOT/.env" || true
      fi
    } >"$tmp"
    if ! grep -Eq "^[[:space:]]*SESSION_SECRET(_FILE)?[[:space:]]*=[[:space:]]*[^[:space:]\"']" "$tmp"; then
      echo "SESSION_SECRET=$(openssl rand -hex 32)" >>"$tmp"
    fi
    mv -f "$tmp" "$ENV_FILE"
    echo "env:      created $ENV_FILE"
  fi
  chmod 600 "$ENV_FILE"
  # Optional LAN listener (plain HTTP) so phones on the home Wi-Fi can reach the server without
  # Tailscale: put BENITO_LAN_PORT=8081 in benito.env. Loopback keeps serving Tailscale Serve.
  local bind="$SERVICE_BIND" lan
  lan="$(grep -E '^[[:space:]]*BENITO_LAN_PORT[[:space:]]*=' "$ENV_FILE" | tail -n 1 |
    sed -E 's/^[^=]*=[[:space:]]*"?([0-9]*)"?.*$/\1/' || true)"
  if [[ -n $lan ]]; then
    bind="$bind,0.0.0.0:$lan"
    echo "lan:      0.0.0.0:$lan (BENITO_LAN_PORT)"
  fi
  set_env_key BIND_ADDR "$bind"
  set_env_key DATABASE_PATH "$DB"
}

db_counts() {
  local db=$1 table
  for table in users families events timers; do
    printf '%s=%s ' "$table" "$(sqlite3 "$db" "SELECT COUNT(*) FROM $table;" 2>/dev/null || echo '?')"
  done
}

remove_db_files() {
  rm -f "$1" "$1-wal" "$1-shm"
}

# One-time copy of the pre-service database (repo server/data.db) into $APP.
migrate_legacy_db() {
  local check old new ts suffix
  if [[ -e "$DB" ]]; then
    echo "database: $DB (existing, untouched)"
    return 0
  fi
  if [[ ! -f "$LEGACY_DB" ]]; then
    echo "database: none yet; the server will create $DB"
    return 0
  fi
  if port_in_use; then
    lsof -nP -iTCP:"$SERVICE_PORT" -sTCP:LISTEN >&2 || true
    die "something is listening on port $SERVICE_PORT (likely the old server using $LEGACY_DB). Stop it, then re-run install."
  fi

  echo "database: migrating $LEGACY_DB -> $DB"
  if ! sqlite3 "$LEGACY_DB" ".backup '$DB'"; then
    remove_db_files "$DB"
    die "sqlite3 .backup failed; legacy database untouched"
  fi
  check="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1 || true)"
  if [[ "$check" != "ok" ]]; then
    remove_db_files "$DB"
    die "integrity_check on the copy failed: $check (copy removed, legacy untouched)"
  fi
  old="$(db_counts "$LEGACY_DB")"
  new="$(db_counts "$DB")"
  echo "  legacy: $old"
  echo "  new:    $new"
  if [[ "$old" != "$new" ]]; then
    remove_db_files "$DB"
    die "row counts differ (copy removed, legacy untouched)"
  fi

  # Rename so nothing (e.g. run-server.sh) can keep writing to the old copy by accident.
  ts="$(date +%Y%m%d-%H%M%S)"
  for suffix in "" -wal -shm; do
    if [[ -e "$LEGACY_DB$suffix" ]]; then
      mv "$LEGACY_DB$suffix" "$LEGACY_DB.migrated-$ts$suffix"
    fi
  done
  echo "  legacy renamed to $LEGACY_DB.migrated-$ts"
}

# Reads plist XML on stdin; lints before atomically replacing the destination.
write_plist() {
  local dest=$1 tmp
  tmp="$(mktemp "$dest.XXXXXX")"
  cat >"$tmp"
  if ! plutil -lint -s "$tmp"; then
    rm -f "$tmp"
    die "generated plist is invalid: $dest"
  fi
  chmod 644 "$tmp"
  mv -f "$tmp" "$dest"
}

write_plists() {
  mkdir -p "$AGENTS_DIR"
  write_plist "$SERVER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$SERVER_BIN</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BENITO_ENV_FILE</key>
    <string>$ENV_FILE</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>$APP</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$SERVER_LOG</string>
  <key>StandardErrorPath</key>
  <string>$SERVER_LOG</string>
</dict>
</plist>
EOF
  write_plist "$BACKUP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$BACKUP_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$BACKUP_SCRIPT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>BENITO_DB</key>
    <string>$DB</string>
    <key>BENITO_BACKUP_DIR</key>
    <string>$BACKUP_DIR</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>3</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>RunAtLoad</key>
  <false/>
  <key>StandardOutPath</key>
  <string>$BACKUP_LOG</string>
  <key>StandardErrorPath</key>
  <string>$BACKUP_LOG</string>
</dict>
</plist>
EOF
  echo "plists:   $SERVER_PLIST"
  echo "          $BACKUP_PLIST"
}

cmd_install() {
  local reinstall=0 src
  need cargo sqlite3 curl openssl plutil lsof launchctl
  if is_loaded "$SERVER_LABEL"; then
    reinstall=1
  elif port_in_use; then
    # Otherwise the health check below would pass against the wrong process.
    lsof -nP -iTCP:"$SERVICE_PORT" -sTCP:LISTEN >&2 || true
    die "port $SERVICE_PORT is already in use by a process launchd doesn't manage (old foreground server?). Stop it, then re-run install."
  fi

  echo "building release binary..."
  (cd "$ROOT/server" && cargo build --release)
  src="$ROOT/server/target/release/benito-server"
  [[ -x "$src" ]] || die "build output missing: $src"

  mkdir -p "$BIN_DIR" "$LOG_DIR"
  install_file "$src" "$SERVER_BIN"
  install_file "$ROOT/scripts/backup-db.sh" "$BACKUP_SCRIPT"
  echo "binary:   $SERVER_BIN"

  write_env_file
  migrate_legacy_db
  write_plists

  unload "$SERVER_LABEL"
  launchctl bootstrap "$DOMAIN" "$SERVER_PLIST"
  if ((reinstall)); then
    launchctl kickstart -k "$DOMAIN/$SERVER_LABEL"
  fi
  unload "$BACKUP_LABEL"
  launchctl bootstrap "$DOMAIN" "$BACKUP_PLIST"
  echo "loaded:   $SERVER_LABEL, $BACKUP_LABEL (backup daily at 03:30 -> $BACKUP_DIR)"

  health_wait
}

cmd_uninstall() {
  need launchctl
  unload "$SERVER_LABEL"
  unload "$BACKUP_LABEL"
  rm -f "$SERVER_PLIST" "$BACKUP_PLIST"
  echo "removed LaunchAgents $SERVER_LABEL and $BACKUP_LABEL"
  echo "kept (delete by hand if you really mean it):"
  echo "  database: $DB"
  echo "  env:      $ENV_FILE"
  echo "  binaries: $BIN_DIR"
  echo "  backups:  $BACKUP_DIR"
  echo "  logs:     $LOG_DIR"
}

cmd_restart() {
  is_loaded "$SERVER_LABEL" || die "$SERVER_LABEL is not loaded; run: $0 install"
  launchctl kickstart -k "$DOMAIN/$SERVER_LABEL"
  health_wait
}

cmd_status() {
  local label newest=""
  local backups=()
  for label in "$SERVER_LABEL" "$BACKUP_LABEL"; do
    echo "$label:"
    if is_loaded "$label"; then
      launchctl print "$DOMAIN/$label" \
        | grep -E $'^\t(state|pid|runs|last exit code|last exit status|last exit reason) =' \
        | sed $'s/^\t/  /' || true
    else
      echo "  not loaded"
    fi
  done

  if curl -sf --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "health:   ok ($HEALTH_URL)"
  else
    echo "health:   NOT responding ($HEALTH_URL); see $SERVER_LOG"
  fi

  if [[ -f "$DB" ]]; then
    echo "database: $DB ($(du -h "$DB" | cut -f1))"
  else
    echo "database: $DB (missing)"
  fi

  shopt -s nullglob
  backups=("$BACKUP_DIR"/benito-*.db)
  shopt -u nullglob
  if ((${#backups[@]} > 0)); then
    newest="${backups[${#backups[@]}-1]}"
    echo "backup:   $newest ($(du -h "$newest" | cut -f1)); ${#backups[@]} in $BACKUP_DIR"
  else
    echo "backup:   none yet in $BACKUP_DIR"
  fi
}

cmd_logs() {
  [[ -f "$SERVER_LOG" ]] || die "no log yet at $SERVER_LOG"
  exec tail -n 100 -f "$SERVER_LOG"
}

cmd_backup_now() {
  local i out
  is_loaded "$BACKUP_LABEL" || die "$BACKUP_LABEL is not loaded; run: $0 install"
  launchctl kickstart "$DOMAIN/$BACKUP_LABEL"
  # Wait (up to ~2 min) for the one-shot job to finish before showing its log.
  sleep 1
  for ((i = 0; i < 120; i++)); do
    out="$(launchctl print "$DOMAIN/$BACKUP_LABEL" 2>/dev/null || true)"
    [[ "$out" == *$'\n\tstate = running'* ]] || break
    sleep 1
  done
  if [[ -f "$BACKUP_LOG" ]]; then
    tail -n 5 "$BACKUP_LOG"
  else
    echo "no backup log yet at $BACKUP_LOG"
  fi
}

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only (launchd)"

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  backup-now) cmd_backup_now ;;
  *)
    usage
    exit 2
    ;;
esac
