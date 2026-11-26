# Always-on server on a Mac (launchd)

Run `benito-server` as a launchd **LaunchAgent** so it starts at login, restarts if it crashes, and backs up its SQLite database every night. HTTPS still comes from Tailscale Serve; see [`deploy-tailscale.md`](./deploy-tailscale.md) for that one-time setup and for pointing the app at the server.

## Why a LaunchAgent

A LaunchAgent runs in your login session, not as a root LaunchDaemon. That needs no `sudo`, and it matches Tailscale: the Tailscale GUI app, which terminates HTTPS for the server, only runs while you are logged in too. **Turn on automatic login** (System Settings → Users & Groups → Automatically log in as…) so both come back after a reboot or power cut without anyone at the keyboard.

## Commands

```bash
scripts/macos-service.sh install      # build, install, migrate DB (first run), load agents, wait for /health
scripts/macos-service.sh status       # launchd state/pid/last exit, health, DB size, newest backup
scripts/macos-service.sh restart      # restart the server, wait for /health
scripts/macos-service.sh logs         # tail -f the server log
scripts/macos-service.sh backup-now   # run the backup job immediately and show its log
scripts/macos-service.sh uninstall    # stop and remove both agents; keeps DB, env, backups, logs
```

## File locations

| What | Path |
|---|---|
| Server binary | `~/Library/Application Support/Benito/bin/benito-server` |
| Backup script | `~/Library/Application Support/Benito/bin/backup-db.sh` |
| Environment (secret, bind, DB path; mode 600) | `~/Library/Application Support/Benito/benito.env` |
| Database | `~/Library/Application Support/Benito/benito.db` (+ `-wal`/`-shm`) |
| Logs | `~/Library/Logs/Benito/server.log`, `~/Library/Logs/Benito/backup.log` |
| Backups | `~/Backups/benito/benito-YYYYmmdd-HHMMSS.db` |
| LaunchAgents | `~/Library/LaunchAgents/com.mikeroysoft.benito.server.plist`, `~/Library/LaunchAgents/com.mikeroysoft.benito.backup.plist` |

The server is always bound to `127.0.0.1:8080`; `install` rewrites `BIND_ADDR` and `DATABASE_PATH` in `benito.env` every time and leaves every other line alone.

## First install

1. Stop any server you started by hand (`run-server.sh`, a background job, Docker). `install` refuses to continue while something else listens on port 8080.
2. Run `scripts/macos-service.sh install`. On the first run it:
   - creates `benito.env`, copying `SESSION_SECRET` / `SESSION_SECRET_FILE` / `RUST_LOG` from the repo-root `.env` if there is one (so existing logins keep working), otherwise generating a new secret;
   - migrates an existing `server/data.db` (override with `LEGACY_DB=/path/to/data.db`): copies it with `sqlite3 .backup`, requires `PRAGMA integrity_check` = `ok`, and compares row counts of `users`, `families`, `events`, `timers` between the old and new file. Any failure deletes the copy and leaves the old file alone. On success the old file (and its `-wal`/`-shm`) is renamed to `data.db.migrated-<timestamp>` so nothing can keep writing to it by accident;
   - loads both agents and polls `http://127.0.0.1:8080/health` for up to 15 seconds.

## Updating after `git pull`

Run `scripts/macos-service.sh install` again. It rebuilds, swaps the binary atomically (copy to a temp file, then rename), rewrites the plists and restarts the server. The database and `benito.env` are never touched on a re-run; the migration only happens when `benito.db` does not exist yet.

## Backups

- The backup agent runs `backup-db.sh` daily at **03:30** (launchd catches up after sleep) and keeps the newest **30** `benito-*.db` files. Other files in `~/Backups/benito` (for example older manual `data-*.db` copies) are never pruned.
- `sqlite3 .backup` takes a consistent snapshot while the server keeps running in WAL mode; each snapshot must pass `PRAGMA integrity_check` before it is renamed into place. Every run logs one line (file, size, user/event counts) to `backup.log`.
- Manual run with other settings: `BENITO_DB=… BENITO_BACKUP_DIR=… BENITO_BACKUP_KEEP=… scripts/backup-db.sh`.
- Copy `~/Backups/benito` off the machine too (Time Machine, another disk) — a backup on the same SSD doesn't survive the SSD.

### Restore

```bash
scripts/macos-service.sh uninstall     # or: launchctl bootout gui/$(id -u)/com.mikeroysoft.benito.server
APP="$HOME/Library/Application Support/Benito"
cp "$APP/benito.db" "$APP/benito.db.before-restore"          # optional safety copy
cp ~/Backups/benito/benito-YYYYmmdd-HHMMSS.db "$APP/benito.db"
rm -f "$APP/benito.db-wal" "$APP/benito.db-shm"
scripts/macos-service.sh install       # reloads the agents; the existing benito.db is kept as-is
```

The server must be stopped while you replace the file, and the stale `-wal`/`-shm` files must go with the old database.

## ActivityKit Live Activity push (optional)

Phase 1 ends a partner phone's Dynamic Island when someone else stops a timer, even if that phone is suspended. WebSocket sync still works without this; leave the vars unset until the key is on the host.

1. In [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list) create an **Apple Push Notifications service (APNs)** key (`.p8`). Use your own Team ID (Xcode › Settings › Accounts).
2. Copy the `.p8` somewhere only the LaunchAgent user can read (for example `~/Library/Application Support/Benito/AuthKey_XXXXXX.p8`, mode `600`). **Never commit the key.**
3. Add to `~/Library/Application Support/Benito/benito.env` (then `scripts/macos-service.sh restart`):

```bash
APNS_KEY_PATH=/Users/YOU/Library/Application Support/Benito/AuthKey_XXXXXX.p8
APNS_KEY_ID=XXXXXXXXXX
APNS_TEAM_ID=ABCDE12345
APNS_TOPIC=com.example.benito.push-type.liveactivity
```

The app registers each token with the APNs environment its binary is signed for: **sandbox** for Xcode development builds (`aps-environment` = development), **production** for App Store and TestFlight. The server posts to `api.sandbox.push.apple.com` or `api.push.apple.com` from the stored `apns_env`, so both can be registered at once.

With the key unset the server logs that push is disabled and `timer.stop` only fans out over WebSocket (unchanged).

## Foreground debugging

`scripts/run-server.sh` runs the server in the terminal for debugging. It refuses to start while the launchd service is installed (`uninstall` it first). When `benito.env` exists it uses that secret and `benito.db`; otherwise it falls back to the repo `.env` and `server/data.db`.

## Home Wi-Fi without Tailscale

A babysitter or grandparent on your Wi-Fi can use Benito without installing Tailscale. Add to `~/Library/Application Support/Benito/benito.env`:

```bash
BENITO_LAN_PORT=8081
# Order matters: phones try these top to bottom. Give the Mac a DHCP reservation so the IP doesn't change.
BENITO_PUBLIC_URLS="http://192.168.1.20:8081,https://your-mac.your-tailnet.ts.net"
```

Then run `scripts/macos-service.sh install` again. The server keeps `127.0.0.1:8080` for Tailscale Serve and adds a plain-HTTP listener on port 8081 for the LAN. It also advertises `_benito._tcp` over Bonjour, so the app's setup screen finds it (`BENITO_BONJOUR=0` turns that off). Invites created afterwards carry these URLs, and the joining phone uses the first one that answers.

If the macOS firewall is on, allow incoming connections for `benito-server` the first time it asks. The LAN port is unencrypted: only enable it on a network you trust (see `SECURITY.md`).

