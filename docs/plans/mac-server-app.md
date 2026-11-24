# Plan: Benito Server for Mac

Status: M1 to M4 are built on `main`, uncommitted, as of 2026-11-17. What still needs a person is
listed in section 8.

A Mac app that a parent runs to install and look after `benito-server`: a menubar item for status,
and a window for backups, people and devices, and logs. It replaces "clone the repo, install Rust,
run `scripts/macos-service.sh install`" for families who are not developers.

## 0. Decisions

| Topic | Decision | Why |
|---|---|---|
| Distribution | Developer ID signed, notarized DMG; Sparkle 2 updates. Source is MIT licensed; the repository is still private and has to be public before the first release, because the update feed links to GitHub Release downloads | A source build needs Xcode and Rust, which defeats "the thing you run to install". Supersedes SPEC locked decision 4 for the Mac app. |
| Mac Store | Not now | Sandbox would move the data out of `~/Library/Application Support/Benito` and block driving the Tailscale CLI. |
| Native Mac client | Not built | The iOS target already runs on Apple Silicon as "Designed for iPad". The Mac use case is glancing and administering; the menubar glance covers it. |
| Baby data in the Mac app | Read-only glance (last feed, last diaper, running timer) | Logging from the Mac means enrolling it as a family device; revisit after use. |
| Passwords | No password UI | New accounts are device keys. One legacy email account exists; changing its password is deferred. |
| Process model | Server is a launchd LaunchAgent, separate from the app, installed exactly as `scripts/macos-service.sh` does it | Quitting or crashing the UI must never stop family sync. Same label, plist and paths as the script, so adopting a script install is an in-place upgrade. The reverse is not symmetrical: running the script afterwards installs a source build and brings back the nightly backup job; Update Server undoes that. |
| `SMAppService.agent` | Not used for the server (revised 2026-11-17) | The script's LaunchAgent is proven on this macOS, needs no signed-bundle plist (which cannot hold `$HOME` paths), and keeps the server running when the app is moved or updated. `SMAppService.mainApp` is used only to open the app at login. |
| Who touches SQLite | Only `benito-server` | Keeps "never write under a running server" true by construction. The app talks to the admin API or runs server subcommands. |
| Admin channel | Second listener on loopback with a per-process bearer token | Tailscale Serve proxies to `127.0.0.1:8080`, so admin routes on the public router would be reachable from the tailnet. |
| Backups | Inside the server (SQLite online backup API) | Removes the second LaunchAgent, the bash script and the `sqlite3` CLI dependency; Docker and Linux get backups too. |
| Data layout | Unchanged | An existing `macos-service.sh` install is adopted in place. |
| Repo layout | `apps/BenitoServer/` with its own `project.yml` | Leaves the iOS project and its gates untouched. |

## 1. Architecture

```text
Benito Server.app (menubar + window)
   │  reads  ~/Library/Application Support/Benito/admin.json   {url, token, pid}
   │  HTTP   http://127.0.0.1:<admin port>/admin/…             Authorization: Bearer <token>
   │  runs   benito-server restore <file>                      (server stopped)
   ▼
benito-server (LaunchAgent; the app copies its bundled binary to <data>/bin)
   ├─ public listeners   127.0.0.1:8080 (Tailscale Serve), optional 0.0.0.0:<LAN port>
   ├─ admin listener     127.0.0.1:<port>, never proxied, never on the LAN
   ├─ backup scheduler   benito-YYYYmmdd-HHMMSS.db in the backup folder
   └─ benito.db          the only process that opens it
```

Files (all existing paths keep their meaning):

| What | Path |
|---|---|
| Database | `~/Library/Application Support/Benito/benito.db` (+ `-wal`, `-shm`) |
| Instance lock | `~/Library/Application Support/Benito/benito.db.lock` (new) |
| Admin handoff | `~/Library/Application Support/Benito/admin.json`, mode 600 (new) |
| Config | `~/Library/Application Support/Benito/benito.env`, mode 600 |
| Logs | `~/Library/Logs/Benito/server.log` |
| Backups | `~/Backups/benito/benito-YYYYmmdd-HHMMSS.db` |

## 2. M1: server groundwork (Rust)

Everything here is off unless configured, so Docker, Linux and existing installs behave as before.

### 2.1 Settings

| Env | Default | Meaning |
|---|---|---|
| `BENITO_ADMIN_ADDR` | unset (admin API off) | Loopback address for the admin listener. Port `0` asks the OS for a free one. A non-loopback address is a startup error. |
| `BENITO_ADMIN_FILE` | `admin.json` next to the database | Where the server writes `{"url","token","pid","started_at"}` at startup (mode 600, atomic). Removed on clean shutdown. |
| `BENITO_BACKUP_DIR` | unset (no built-in backups) | Folder for snapshots. Setting it turns on the scheduler and the backup endpoints. |
| `BENITO_BACKUP_KEEP` | `30` | Newest `benito-*.db` files to keep. Other files in the folder are never pruned. |
| `BENITO_BACKUP_INTERVAL_HOURS` | `24` | A snapshot is taken when the newest one is older than this. `0` means on demand only. |

The token is 32 random bytes (hex), new on every start, and never configured. A client that gets
`401` or a refused connection re-reads `admin.json`.

### 2.2 Commands

```text
benito-server                    serve (unchanged default)
benito-server backup             one snapshot into BENITO_BACKUP_DIR; safe while a server runs
benito-server restore <file>     replace the database with a snapshot; refuses while a server runs
benito-server --version
```

`restore`: takes the instance lock (fails if a server holds it), checks the snapshot
(`PRAGMA integrity_check`, has a `users` table), saves the current database as
`pre-restore-YYYYmmdd-HHMMSS.db` in the backup folder (or next to the database when no folder is
set), copies the snapshot beside the database, removes `-wal`/`-shm`, renames it into place, then
opens it once so migrations run. Prints one JSON line.

### 2.3 Runtime behavior

- **Instance lock.** `serve` holds an advisory lock on `<database>.lock`. A second server on the
  same file exits with a clear error instead of sharing it.
- **Graceful shutdown.** SIGTERM and SIGINT stop accepting connections, give open requests and
  WebSockets 5 seconds, checkpoint the WAL (`TRUNCATE`), and remove `admin.json`.
- **Backups.** A second, read-only connection runs the SQLite online backup into a temp file in the
  backup folder, checks integrity, sets mode 600, renames to `benito-YYYYmmdd-HHMMSS.db` (local
  time, same names as `scripts/backup-db.sh`), then prunes. The scheduler looks every 5 minutes and
  snapshots when the newest file is older than the interval, so a Mac that slept catches up on wake.

### 2.4 Admin API

All routes need `Authorization: Bearer <token from admin.json>`. No CORS headers. Errors are
`{"error": "..."}` like the public API.

| Route | Purpose |
|---|---|
| `GET /admin/status` | Version, pid, uptime, server id, database path and size, row counts, listeners, advertised URLs, live sync connections, last event time, backup settings and newest snapshot, whether APNs is configured |
| `GET /admin/glance` | Per child: last feed, last diaper, last medicine, running or paused timer (the `/state` payload plus the child's and family's names) |
| `GET /admin/people` | Every family: members (role, email for password accounts, joined, access end, devices with last seen) and pending invites |
| `POST /admin/invites` | `{family_id?, role?, expires_in_hours?, access_hours?, label?}` → the same body as `POST /families/invites`, including the one-time `secret`. `family_id` may be omitted when there is one family. Recorded as created by the family's first parent |
| `DELETE /admin/invites/{id}` | Revoke a pending invite |
| `DELETE /admin/devices/{id}` | Revoke one device key and end its sessions |
| `DELETE /admin/families/{family_id}/members/{user_id}` | Remove someone: membership, sessions and devices (same as the app's swipe-to-remove, and tells connected phones) |
| `GET /admin/backups` | Snapshots in the backup folder, newest first: name, path, size, modified time |
| `POST /admin/backups` | Take a snapshot now; returns its name, size, and user and event counts |
| `GET /admin/export.csv` | Event CSV for a family; optional `family_id`, `child_id`, `from` (inclusive), `to` (exclusive) |
| `GET /admin/export.json` | The full JSON bundle for a family |

Removing a member is refused (409) when they are the family's only parent: invites are attributed
to a parent, so a family without one could never let anyone in again.

**Recovery this enables.** A passwordless parent whose only phone is lost has no way back in today:
invites need a signed-in parent. With the Mac app they mint a parent invite on the Mac, scan the QR
with the new phone, then remove the old phone from the list.

### 2.5 Tests

`server/tests/admin.rs`: token required and checked; the admin routes are absent from the public
router; status and people reflect seeded data; an admin invite redeems through the public
`/invites/redeem`; revoking a device ends its session. `server/tests/backup.rs`: a snapshot taken
while the server holds the database opens clean and has the rows; pruning keeps the newest N and
leaves other files alone; restore replaces the data, keeps a pre-restore copy, and refuses when the
lock is held.

## 3. M2: app shell (what you can see first)

`apps/BenitoServer/` (XcodeGen, macOS 14+, SwiftUI, depends on BenitoKit for invite links). In M2
the app attaches to a server that is already running with the admin API on; it does not install or
restart anything yet.

- **Menubar item.** Icon shows running, needs attention, or stopped. Popover: status line, version,
  phones connected, newest backup age, the glance per child (hideable), copyable URLs, and buttons
  for Back Up Now, Invite, and Open Benito Server.
- **Window.** Sidebar with four panes:
  - *Overview*: status, uptime, listeners and advertised URLs, database size and counts, glance.
  - *People & Devices*: members and their devices with last seen; remove a person or one device;
    pending invites with revoke; **Invite** shows a QR code and a copyable link.
  - *Backups*: folder, schedule, newest snapshot, the list, Back Up Now, Reveal in Finder.
  - *Logs*: tail of `server.log`, with a filter field.
- **States.** Running (admin API answers); running without admin API (an older server answers
  `/health` on 8080: "installed by `macos-service.sh`, update to manage it here"); stopped; not
  installed.
- **Launch.** The app has no Dock icon until its window is open. It opens the window on every
  launch for now; M3 keeps a launch at login silent.
- **Dev harness.** `scripts/dev-server-app.sh` builds the server, starts it on a free loopback port
  with a scratch database seeded with demo data under `$TMPDIR`, and launches the app pointed at
  that folder (`BENITO_SERVER_HOME`). It never touches `~/Library/Application Support/Benito`.

## 4. M3: the app owns the service

- **Install.** The app carries `benito-server` at `Contents/MacOS/`. Install Server copies it to
  `<data>/bin/benito-server` (temp file, then rename), writes `benito.env` (a new
  `SESSION_SECRET` only when there is none, `DATABASE_PATH`, `BIND_ADDR`, `BENITO_ADMIN_ADDR`,
  `BENITO_BACKUP_DIR`; every other line kept), writes
  `~/Library/LaunchAgents/com.mikeroysoft.benito.server.plist` with the same keys as the script,
  loads it, and waits for the admin API.
- **Adopt and update.** For a server installed by the script, or any installed binary that differs
  from the bundled one: Update Server first takes a snapshot with the bundled binary
  (`benito-server backup`, safe while the old server runs) and stops if that fails. The snapshot is
  renamed `pre-update-YYYYmmdd-HHMMSS.db`, so retention never prunes it. It keeps the
  program it is replacing as `bin/benito-server.previous`, swaps the binary, adds the admin and
  backup settings, and restarts. If the new server does not answer within 15 seconds, the previous
  program, `benito.env` and plist are put back and the old server is started again. Only after the
  new server answers is the old `com.mikeroysoft.benito.backup` agent removed (the server backs
  itself up now). It is always a button, never automatic.
- **Controls.** Start, stop, restart, uninstall (keeps the database, settings, backups and logs),
  and restore from the Backups list (stop, `benito-server restore`, start).
- **Log rotation.** launchd appends to `server.log` forever. Over 5 MB the app copies it to
  `server.log.1` and truncates the live file in place.
- **Connections pane.** Home Wi-Fi (LAN port, Bonjour name, plain-HTTP warning, changed-address
  warning), Tailscale (finds the CLI, shows the Mac's tailnet name and whether Serve forwards to
  the server, can turn Serve on after showing the exact command), a reachability test per address,
  and one Apply that rewrites `BIND_ADDR`, `BENITO_LAN_PORT`, `BENITO_BONJOUR_NAME` and
  `BENITO_PUBLIC_URLS` and restarts the server.
- **Getting started.** While the server has no family, Overview shows the steps: connect phones,
  create the family on an iPhone at one of the addresses, then invite everyone else from the Mac.
  The first phone creates the family; the Mac cannot, because a family needs a parent's device key.
- **Reliability pane.** Opens at login, automatic login, sleep, firewall, backups (and whether they
  share a disk with the database), free disk space; optional notifications for a stopped server, a
  failed or overdue backup, and low disk space.
- **Export pane.** CSV by child and date range, or everything as JSON, through
  `GET /admin/export.csv` and `GET /admin/export.json`.
- **Launch.** Opened by a person, the app shows its window; opened as a login item it stays in the
  menu bar.
- **Testing without the real service.** With `BENITO_SERVER_HOME` set the app uses a different
  launchd label (`com.mikeroysoft.benito.server.dev-<hash>`), a free port, and that folder for all
  data. `scripts/dev-server-app.sh --managed` starts the app that way with nothing installed.

## 5. M4: distribution

- `scripts/release-mac.sh`: universal server (`aarch64` + `x86_64`, `lipo`), archive with Developer
  ID and the hardened runtime, DMG, notarize, staple, Sparkle appcast. `--unsigned` runs the same
  steps with ad-hoc signing for a local check. Guide: `docs/release-mac.md`.
- Sparkle 2 in the app, off unless the build carries `BENITO_SPARKLE_PUBLIC_KEY`. Before an update
  relaunches the app, the server takes a snapshot. After it, the app offers Update Server.
- A release workflow under `.github/workflows/` and a Mac build gate in `.factory.toml` are
  protected paths; `docs/release-mac.md` has both ready to paste.

## 6. Security notes

- The admin listener binds loopback only and is a different port from anything Tailscale Serve or
  the LAN listener exposes. The token gates other local users and browser pages; a process running
  as the same user can already read the database file, so it is not a boundary against that.
- `admin.json` is a secret, like `benito.env`. Agents and support tooling must not read it.
- Admin invites are ordinary invites: single use, hashed secret, 72 hours by default.
- The glance shows a baby's health data on a Mac screen. The menubar has a switch to hide it.

## 7. Open questions

1. Whether the app should update the server by itself after a Sparkle update. Today it asks.
2. Encrypting snapshots at rest (they are a baby's health record). Not planned; revisit if backups
   go to shared or cloud folders.
3. Logging from the Mac (enroll it as a family device). Deferred until the glance has been used.

## 8. What needs a person

- Adopting the live install on the family Mac: open the released app and press Update Server.
- A Developer ID Application certificate, a notarytool keychain profile, and a Sparkle key pair
  (`docs/release-mac.md`). None exist on the development Mac, so a signed release has not been cut.
- The two protected files above.
- An app icon. The app uses the system default.

## 9. Takeover rehearsal (2026-11-17)

Run on a copy, under a scratch launchd label: the newest nightly backup as the database, the
server program the family Mac runs today (built Oct 23, no admin API), a script-style `benito.env`
and plist. Update Server took under a second. Before and after: 3 users, 2 families, 2 children,
1,334 events (1,287 not deleted), 2 active devices, 7 sessions, 615 timers, all unchanged. The new
server answered `/health` and the admin API, the pre-update snapshot and `benito-server.previous`
were in place, and the CSV export matched the event count. The copy was deleted afterwards.

Not covered by the rehearsal: removing the old backup agent (default home only), phones
reconnecting, the firewall prompt for the new program, and Tailscale Serve.

## 10. Click-through checklist

With `scripts/dev-server-app.sh --managed` (nothing real is touched):

1. Window opens on Overview with Install Server. Press it: status turns Running within seconds.
2. Menu bar icon: popover shows Running, version, Back Up Now, Restart.
3. Overview: Getting Started is shown; Open Connections switches pane.
4. Connections: turn on Home Wi-Fi, see this Mac's address and the plain-HTTP warning, Apply,
   server restarts, the address appears under Addresses for Phones, Test shows reachable.
   macOS may ask for Local Network access here. Tailscale shows status; Turn On is not offered.
5. Backups: Back Up Now adds a row. Select it, Restore, read the dialog, confirm: result line
   names a `pre-restore-` file.
6. Overview: Stop (dialog), then Start; Restart; Uninstall Service (dialog says what is kept).
7. Export: with no family yet the pane says so. With `scripts/dev-server-app.sh` (demo family):
   Export CSV opens a save panel and the file has one line per entry.
8. People & Devices (demo family): Invite shows a QR and link; Remove on the only parent is
   refused with a message; Revoke on Ben's iPhone asks first.
9. Reliability: every row shows a state; turning on Notifications asks for permission; Opens at
   Login toggles (an unsigned build may show "could not check").
10. Logs: lines appear and the filter narrows them.
11. Quit from the popover: the scratch service is removed by the script.
