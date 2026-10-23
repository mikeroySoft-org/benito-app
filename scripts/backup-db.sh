#!/usr/bin/env bash
# Snapshot the Benito SQLite database into a timestamped, integrity-checked backup file.
# Run nightly by the launchd backup agent (scripts/macos-service.sh); also safe to run by hand
# while the server is up: sqlite3 .backup takes a consistent snapshot even in WAL mode.
#
#   BENITO_DB           database to back up  (default: ~/Library/Application Support/Benito/benito.db)
#   BENITO_BACKUP_DIR   destination folder   (default: ~/Backups/benito)
#   BENITO_BACKUP_KEEP  benito-*.db files to keep, newest first (default: 30)
#
# Only files named benito-*.db are pruned; anything else in the folder is left alone.
set -euo pipefail
umask 077

DB="${BENITO_DB:-$HOME/Library/Application Support/Benito/benito.db}"
DIR="${BENITO_BACKUP_DIR:-$HOME/Backups/benito}"
KEEP="${BENITO_BACKUP_KEEP:-30}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fail() { log "backup FAILED: $*" >&2; exit 1; }

tmp=""
cleanup() { if [[ -n "$tmp" ]]; then rm -f "$tmp"; fi; }
trap cleanup EXIT
trap 'fail "unexpected error at line $LINENO"' ERR

[[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || fail "BENITO_BACKUP_KEEP must be a positive integer (got '$KEEP')"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 not found on PATH"
# Check first: sqlite3 would silently create an empty database at a wrong path.
[[ -f "$DB" ]] || fail "database not found: $DB"
mkdir -p "$DIR"

# Temp file lives in the backup dir so the final rename is atomic (same filesystem).
tmp="$DIR/.benito-backup.$$.tmp"
sqlite3 -cmd ".timeout 5000" "$DB" ".backup '$tmp'" || fail "sqlite3 .backup of $DB failed"

check="$(sqlite3 "$tmp" 'PRAGMA integrity_check;' 2>&1)" || fail "integrity_check could not run: $check"
[[ "$check" == "ok" ]] || fail "integrity_check on snapshot: $check"

users="$(sqlite3 "$tmp" 'SELECT COUNT(*) FROM users;')" || fail "could not count users"
events="$(sqlite3 "$tmp" 'SELECT COUNT(*) FROM events;')" || fail "could not count events"
size="$(wc -c <"$tmp" | tr -d '[:space:]')"

dest="$DIR/benito-$(date +%Y%m%d-%H%M%S).db"
[[ -e "$dest" ]] && dest="${dest%.db}-$$.db"
mv "$tmp" "$dest"
tmp=""

# Timestamped names sort chronologically, so the oldest are at the front of the glob.
shopt -s nullglob
backups=("$DIR"/benito-*.db)
shopt -u nullglob
pruned=0
if ((${#backups[@]} > KEEP)); then
  for old in "${backups[@]:0:${#backups[@]}-KEEP}"; do
    rm -f "$old"
    pruned=$((pruned + 1))
  done
fi

log "backup ok file=$dest size=${size}B users=$users events=$events kept=$((${#backups[@]} - pruned)) pruned=$pruned"
