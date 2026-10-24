---
name: benito
description: Install, run, and read a self-hosted Benito baby tracker server (benito-server, SQLite) to answer a parent's questions, such as when the baby last ate, how much they slept, diaper counts, crying trends, or a CSV for the pediatrician. Use when the user mentions Benito, their baby log, or asks you to set up, upgrade, back up, troubleshoot, or query their Benito server. Read-only by default.
---

# Benito: self-host the server and read the baby log

Benito is a free, open-source baby tracker. Parents log feeds, sleep, diapers, and more on their
iPhones. The iPhones sync to a small Rust server (`benito-server`) that the family runs on their
own Mac or Linux box, with one SQLite file holding everything. This skill shows you how to install
and look after that server, and how to read the database to answer questions like "when did she
last eat?" or "is he sleeping less this week?".

Everything below was checked against the code in this repo (`server/src`, `scripts/`) and a
scratch server. Where a path was not exercised, it says so.

## Ground rules (read first)

1. **Read-only by default.** Use `scripts/benito-query` or `sqlite3 -readonly`. Never write to
   the database to "fix" data. Parents fix entries in the app, where the change syncs to every phone.
2. **Never edit the database while the server is running.** The server holds the file open in WAL
   mode and caches state. Writing underneath it can corrupt the file or be silently overwritten.
3. **Back up, then ask.** Before any change to the server, its config, or the database (upgrade,
   restore, reinstall, migration), take a backup (see Operate) and get the human's explicit OK
   for that specific change.
4. **The data is private.** It is a baby's health record. Keep it on the user's machine: do not
   upload the database, CSVs, or query results to any web service, paste them into an issue, or
   send them anywhere the user did not ask for. Summarize in chat; write files only locally.
5. **Never read secrets.** Skip the `sessions`, `pairing_tokens`, `live_activity_tokens`, and
   `devices` tables, `users.password_hash`, and `benito.env` (it holds `SESSION_SECRET`). The
   helper never touches them. A bearer token in a terminal is the same as a password.
6. **You are not a doctor.** Report what was logged, plainly and without judgment. For anything
   medical (fever, too few wet diapers, weight, feeding or sleep worries, medicine doses) say
   so and point the parent to their pediatrician, or emergency services if it sounds urgent.
   Do not diagnose or give dosing advice.
7. **Do not take a running server down without asking.** Check what is listening before you
   install, and do not reuse a port another service owns.

## Where things live

| What | macOS service install | Docker Compose | Foreground (`run-server.sh`) |
|---|---|---|---|
| Database | `~/Library/Application Support/Benito/benito.db` | `/data/data.db` in volume `benito-data` | `DATABASE_PATH`, default `server/data.db` |
| Config | `~/Library/Application Support/Benito/benito.env` (mode 600) | env vars in `docker-compose.yml` | repo `.env` / env vars |
| Logs | `~/Library/Logs/Benito/server.log`, `backup.log` | `docker compose logs` | terminal |
| Backups | `~/Backups/benito/benito-YYYYmmdd-HHMMSS.db` (nightly 03:30, keeps 30) | none built in | none built in |
| Health | `curl -s http://127.0.0.1:8080/health` returns `{"service":"benito-server","status":"ok","version":"0.1.0"}` | same, on `BENITO_PORT` | same |

If the user chose **on-device mode** in the app, there is no server: the data lives only on the
iPhone. Ask them to export a CSV from the app if they want you to look at it.

## Install and self-host

Ask first which host they want (an always-on Mac is the main path) and how phones will reach it
(same Wi-Fi only, or Tailscale for away-from-home; see `docs/deploy-tailscale.md`).

### macOS (recommended): LaunchAgent service

Before installing, see what already runs:

```bash
launchctl print "gui/$(id -u)/com.mikeroysoft.benito.server" 2>/dev/null | grep -E 'state|pid'
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(8080|8081|8082) '
```

If Benito is already installed, `install` is an **upgrade** and restarts the live server: back up
first (Operate) and confirm with the human. Then, from a clone of the repo:

```bash
scripts/macos-service.sh install
```

What it does (`scripts/macos-service.sh`):

- Needs `cargo`, `sqlite3`, `curl`, `openssl`, `plutil`, `lsof`, `launchctl` (install Rust from rustup.rs).
- Refuses if port 8080 is held by something that is not the Benito service. The service port is
  fixed at 8080 on loopback.
- Runs `cargo build --release`, copies the binary and `backup-db.sh` into
  `~/Library/Application Support/Benito/bin/`, and swaps the binary atomically.
- Writes `benito.env` once (mode 600), reusing `SESSION_SECRET` from the repo `.env` or generating
  one. Later installs keep it.
- **Rewrites `BIND_ADDR` and `DATABASE_PATH` in `benito.env` on every install.** Hand edits to
  `BIND_ADDR` are lost. To listen on the LAN, set `BENITO_LAN_PORT` instead (below).
- Migrates an old `server/data.db` into the app folder after an integrity check.
- Loads two LaunchAgents: `com.mikeroysoft.benito.server` (starts at login, restarts on crash) and
  `com.mikeroysoft.benito.backup` (daily 03:30). It waits up to 15 s for `/health`.

The service is a LaunchAgent, so it runs while the user is logged in. For an always-on Mac,
turn on automatic login and keep it from sleeping.

**LAN access and Bonjour.** Phones on the same Wi-Fi need a non-loopback listener. Add a port that
nothing else uses to `benito.env`, then reinstall (after a backup and the human's OK):

```bash
lsof -nP -iTCP:8082 -sTCP:LISTEN          # must print nothing (pick another port if it does)
echo 'BENITO_LAN_PORT=8082' >> ~/Library/Application\ Support/Benito/benito.env
scripts/macos-service.sh install          # BIND_ADDR becomes 127.0.0.1:8080,0.0.0.0:8082
```

When bound beyond loopback, the server advertises `_benito._tcp` over Bonjour
(`dns-sd -B _benito._tcp` lists it) so the app can find it. `BENITO_BONJOUR_NAME` sets the name
(default "Benito"); `BENITO_BONJOUR=0` turns it off. `BENITO_PUBLIC_URLS` (comma-separated
origins, LAN first) is what invite links and QR codes hand to a partner's phone. The docs' example
LAN port is 8081; check it is free before using it.

**Uninstall** (`scripts/macos-service.sh uninstall`) unloads both agents and keeps the database,
config, backups, and logs.

### Linux / Docker

Supported in the repo but not covered by this skill's automated checks:

- **Docker Compose** (`docker-compose.yml`, `server/Dockerfile`):
  ```bash
  export SESSION_SECRET="$(openssl rand -hex 32)"
  docker compose up -d --build      # publishes 127.0.0.1:${BENITO_PORT:-8080}
  curl -s http://127.0.0.1:8080/health
  ```
  Data is in the `benito-data` volume at `/data/data.db`. Compose publishes on loopback only by
  design: put Tailscale Serve or a reverse proxy in front, and type that URL into the app (Bonjour
  from inside the container will not reach the LAN). Keep `SESSION_SECRET` stable: changing it
  logs every phone out.
- **Bare metal:** `cargo build --release` in `server/`, then run the binary with `BIND_ADDR`,
  `DATABASE_PATH`, and `SESSION_SECRET` set. The repo has no systemd unit yet; write one with the
  human if they want it. Bonjour on Linux uses `avahi-publish` if installed.
- **Public internet:** follow `docs/deploy-vps.md` (Caddy or nginx with TLS, ufw, rate limits).
  Never expose port 8080 directly.

## Operate

```bash
scripts/macos-service.sh status      # agents, health, DB size, newest backup (read-only)
scripts/macos-service.sh logs        # tail -f server.log (Ctrl-C to stop)
scripts/macos-service.sh backup-now  # run the backup job now and show its log line
scripts/macos-service.sh restart     # ask first: briefly interrupts syncing
```

**Back up before any change.** `backup-now` uses `sqlite3 .backup`, which is safe while the server
runs. Without the service, run the same script by hand:

```bash
BENITO_DB=~/Library/Application\ Support/Benito/benito.db \
BENITO_BACKUP_DIR=~/Backups/benito scripts/backup-db.sh
# ... backup ok file=.../benito-20261023-170108.db size=180224B users=1 events=35 kept=1 pruned=0
```

Do not back up with `cp` while the server runs: it can miss data still in `benito.db-wal`.

**Upgrade:** `git pull`, back up, then `scripts/macos-service.sh install` (with the human's OK).
Schema migrations run automatically at startup.

**Restore** (always with the human's OK; it replaces current data):

```bash
APP=~/Library/Application\ Support/Benito
scripts/macos-service.sh uninstall                 # stop; keeps files
cp "$APP/benito.db" "$APP/benito.db.before-restore"
cp ~/Backups/benito/benito-YYYYmmdd-HHMMSS.db "$APP/benito.db"
rm -f "$APP/benito.db-wal" "$APP/benito.db-shm"
scripts/macos-service.sh install
```

### Troubleshooting

| Symptom | Check | Fix |
|---|---|---|
| `install` says port 8080 is in use | `lsof -nP -iTCP:8080 -sTCP:LISTEN` | Another app owns 8080. The service port is fixed; stop that app or run Benito in Docker on another `BENITO_PORT`. |
| Phones on Wi-Fi cannot connect after a reinstall | `grep BIND_ADDR "$APP/benito.env"` shows only `127.0.0.1:8080` | Someone edited `BIND_ADDR` by hand and install rewrote it. Set `BENITO_LAN_PORT` and reinstall. |
| LAN port conflict | `lsof -nP -iTCP:<port> -sTCP:LISTEN` | Choose a free port for `BENITO_LAN_PORT`. |
| Health not responding | `tail -50 ~/Library/Logs/Benito/server.log` | Read the error. A bad `benito.env` line or a missing database directory are common. |
| Server stopped after reboot | `status` shows "not loaded" | The Mac is not logged in. Turn on automatic login. |
| App cannot find the server | `dns-sd -B _benito._tcp` | Bonjour needs a LAN listener; check that `BENITO_BONJOUR` is not `0`. |
| `run-server.sh` refuses to start | service is loaded | Expected: it will not run a second copy against the same DB. Use the service. |
| Everyone logged out | `SESSION_SECRET` changed | Restore the old value in `benito.env` if known; otherwise sign in again on each phone. |

## Read the database

### The helper: `scripts/benito-query`

A single Python 3.9+ script, standard library only. It opens the file read-only three ways:
a `mode=ro` URI, `PRAGMA query_only`, and an SQLite authorizer that allows only reads. It cannot
create a missing file, and it is safe while the server runs.

```bash
Q=skills/benito/scripts/benito-query       # path from the repo root
$Q info                                    # children, event counts, active timers
$Q --child Benito last-feed
$Q --child Benito timers                   # what is running right now
$Q --child Benito today                    # today so far, local midnight to now
$Q --child Benito day 2026-10-20
$Q --child Benito sleep --days 7           # also: feeds, diapers, crying; or --start/--end
$Q --child Benito events --date 2026-10-22 [--type diaper]
$Q --child Benito export-csv --start 2026-10-01 --end 2026-10-23 --out ~/Desktop/benito.csv
$Q sql "SELECT type, COUNT(*) FROM events WHERE deleted_at IS NULL GROUP BY type"
```

Options: `--db PATH` (else `$BENITO_DB`, else the macOS default path), `--tz America/Los_Angeles`
(else `$BENITO_TZ`, `$TZ`, then the computer's zone), `--child NAME|ID` (required when the family
has more than one child), `--json` for structured output, `--now ISO` to answer "as of" a time.
Use the parent's time zone: the app counts days from their local midnight.

Example (seeded demo data, from `tests/fixture.sql`):

```text
$ benito-query --child Benito day 2026-10-20
Benito, Tue Oct 20 2026 [America/Los_Angeles midnight to midnight]
feeds:   2 nursing (L 1, R 0, 10m), 1 bottle (4.06 oz), 0 solid
sleep:   5.13 h across 1 sleep(s)
diapers: 2 wet, 1 dirty, 0 both
crying:  23m; walks 0m; car rides 30m
other:   1 pump, 0 medicine; 10 events total

$ benito-query --child Benito timers
sleep: running, 40m active since Fri Oct 23 4:09 PM (paused 10m)
feed_breast L: paused, 4m active since Fri Oct 23 4:53 PM (paused 2m)

$ benito-query sql "DELETE FROM events"
benito-query: refused: benito-query is read-only (not authorized)      # exit 2
```

`day`/`today` numbers match the app's daily summary (`GET /summary/daily`). The test suite checks
this against a live server for every day in three time zones.

### Counting rules (match the app)

- **Storage is UTC.** Timestamps are RFC 3339 text such as `2026-10-22T18:00:00+00:00`, sometimes
  with fractional seconds. Convert to the parent's zone before you talk about times or days.
- **A day is local midnight to local midnight** in the parent's zone. DST days are 23 or 25 hours.
- **Counts** (feeds, diapers, pumps, medicine) use events that *start* inside the day.
- **Durations** (sleep, nursing, crying) use finished events that *overlap* the day, clipped at
  midnight. An overnight sleep is split across both days.
- **Open-ended events count 0** toward durations (`ended_at` NULL: a feed or sleep someone forgot
  to stop, or one still running). Mention them instead of guessing a length.
- **Paused time is excluded.** Events made from a paused timer carry
  `payload_json = {"paused_seconds": N}`; subtract it, scaled to the clipped part.
- **Bottle volume:** `amount_unit = 'ml'` counts as ml, anything else as oz;
  `oz_equiv = oz + ml / 29.5735`.
- **Diapers:** subtype `wet`; `dirty`/`poop`/`bm`; `both`/`mixed`; anything else is "other".
- **Nursing side:** `L`/`l`/`left` and `R`/`r`/`right`.
- **"Since last feed"** is measured from when the last `feed_*` event *started*, as in the app.
- **Deleted entries** stay as tombstones with `deleted_at` set. Always filter `deleted_at IS NULL`.
- **Running timers** live in `timers`. They become an event only when stopped.
  Active time = now − `started_at` − `paused_seconds` − (now − `paused_at` if paused).

### Plain `sqlite3`

Fine for quick looks; always pass `-readonly`. Ready-made, tested queries are in
[`references/queries.sql`](references/queries.sql). Run them with the parent's zone so
`'localtime'` means their day:

```bash
DB=~/Library/Application\ Support/Benito/benito.db
TZ=America/Los_Angeles sqlite3 -readonly "$DB" < skills/benito/references/queries.sql
sqlite3 -readonly -header -csv "$DB" "SELECT ... FROM events WHERE deleted_at IS NULL" > ~/Desktop/benito.csv
```

The plain-SQL sleep and crying queries bucket by *start* day and do not clip at midnight, so an
overnight sleep lands entirely on the night it began. Use the helper for numbers that match the app.

Schema, event types, and payloads: [`references/schema.md`](references/schema.md).

### Docker database

The container image has no `sqlite3`. Copy all three files out and read the copy:

```bash
docker compose cp benito:/data/data.db ./benito-copy.db
docker compose cp benito:/data/data.db-wal ./benito-copy.db-wal 2>/dev/null || true
benito-query --db ./benito-copy.db info
```

Delete the copy when done. It is the family's full baby log.

## Answering questions well

- Lead with the answer in the parent's words and local time: "Last feed: 11:00 AM, left side,
  20 min. That was about 6 hours ago."
- Say what the numbers cover: "today so far", "Mon–Sun", "logged entries". The log only shows what
  someone tapped. A missing diaper may just be unlogged.
- Note open-ended or running entries ("a sleep started at 9:40 PM has no end time, so it isn't
  counted").
- Trends: compare like with like (full days, the same weekdays), and give the numbers, not a
  verdict. Add the pediatrician line when the question is medical.
- For a doctor visit, offer `export-csv` for the requested date range, saved locally.

## Reading through the API (optional)

If the server runs on another machine, or you would rather not touch the file, the HTTP API serves
the same numbers. It needs a bearer token, and phones sign in with a device key, so a token only
exists if the human creates an email/password login and gives it to you
(`POST /auth/login {"email","password"}` returns `{"token": ...}`). Never take a token from the
database or from a phone.

```bash
H="Authorization: Bearer $BENITO_TOKEN"; S=http://127.0.0.1:8080
curl -s -H "$H" $S/children
curl -s -H "$H" "$S/state?child_id=$CHILD"                       # last feed/sleep/diaper, timers
curl -s -H "$H" --get $S/summary/daily --data-urlencode child_id=$CHILD \
     --data-urlencode from=2026-10-20T07:00:00Z --data-urlencode to=2026-10-21T07:00:00Z
curl -s -H "$H" $S/export.csv > benito.csv                       # all events
```

Pass `from`/`to` as the parent's local midnights in UTC. Without them, `day=` is a UTC day.
Future work: scoped, read-only agent tokens, so a human can grant access without sharing a login.

## Testing this skill

```bash
python3 skills/benito/tests/test_benito_query.py                     # fixture DB, no server needed
cd server && cargo build --locked && cd ..
python3 skills/benito/tests/test_benito_query.py --server server/target/debug/benito-server
```

The `--server` run starts a scratch server on a temp DB and a free loopback port. It seeds demo
data through the API (`tests/seed.py`) and compares the helper with `/summary/daily` and `/state`.
`--write-fixture` regenerates `tests/fixture.sql` (tokens and password hashes stripped). Never point
the tests at a real family database.
