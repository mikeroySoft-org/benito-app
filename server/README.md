# benito-server

Rust (axum) + SQLite sync API for Benito. One binary, one DB file.

## Local run

```bash
cd server
cargo run
# or
cargo run --release
```

Defaults:

| Env | Default |
|---|---|
| `BIND_ADDR` | `127.0.0.1:8080` (loopback; front with Tailscale Serve or a reverse proxy for TLS — Docker sets `0.0.0.0:8080` in-container) |
| `DATABASE_PATH` or `DATABASE_URL` | `data.db` (`sqlite:` prefix stripped) |
| `SESSION_SECRET` | `dev-only-change-me` (change for real deploys) |
| `SESSION_SECRET_FILE` | optional path to a file containing the secret |
| `.env` / `BENITO_ENV_FILE` | dotenv-style file (repo root or cwd); does not override existing env |
| `BIND_ADDR` (list) | Comma-separated listeners, e.g. `127.0.0.1:8080,0.0.0.0:8081` (loopback for Tailscale Serve plus a LAN port) |
| `BENITO_PUBLIC_URLS` | Comma-separated origins put into invites, LAN first. The inviter's current URL is always added |
| `BENITO_BONJOUR_NAME` / `BENITO_BONJOUR` | Bonjour service name for `_benito._tcp` (default `Benito`); `0` disables advertising. Only advertised when bound beyond loopback |

Health check: `curl http://127.0.0.1:8080/health`

Optional ActivityKit push (no-op when unset — WebSocket still works):

| Env | Purpose |
|---|---|
| `APNS_KEY_PATH` | Path to AuthKey_*.p8 (never commit) |
| `APNS_KEY_ID` | Key ID from Apple Developer |
| `APNS_TEAM_ID` | Your Apple Developer Team ID |
| `APNS_TOPIC` | `<your bundle id>.push-type.liveactivity` |

`POST /live-activity/tokens` `{ "token", "apns_env": "sandbox"|"production", "activity_id"? }` (requires `X-Client-Id`) upserts this device's update token. `DELETE /live-activity/tokens` removes tokens for that client (sign-out); optional `?token=` deletes one. On `POST /timers/{id}/stop` the server fans out an ActivityKit `end` push to the family's tokens except the originating client — payload matches local end (cleared ContentState + immediate dismissal). See `docs/deploy-macos.md`.



## Auth flow (v1a)

1. `POST /auth/register` `{ "name", "email", "password" }` → `{ token, user }`
2. `POST /families` (Bearer) `{ "name", "child_name", "child_birthdate?", "child_sex?" }` → family + child + invite_code
3. Second parent: register + `POST /families/join` `{ "invite_code" }`, **or** proximity pairing (SharePlay/AirDrop): a member calls `POST /families/pairing-tokens` → `{ "token", "family_name", "expires_at" }` (single-use, 5-minute TTL; minting doesn't revoke earlier tokens), hands the token over, and the joiner calls `POST /families/pair` `{ "token" }` → `Family` (same as join). Unknown/expired/used token → 404; redeemer already in a family → 409 (token not consumed); minting without a family → 404.
   To switch families (mostly troubleshooting/dev): `POST /families/leave` removes the caller's membership (`{ "left": true }`; 404 if not in a family). The family and its data stay for the remaining members; already-open `WS /sync` connections for that user keep streaming until they reconnect.
4. `GET /me` → user + family + children
5. `DELETE /me` (Bearer) deletes the caller's account → `{ "deleted": true }`. If they are the last member, the family and its whole history go too; otherwise the family stays and events they logged remain, attributed to `Former member`. Their sessions, device keys, push tokens and unused invites are removed, and the email is free to register again.

Sessions are bearer tokens valid for 30 days and **slide** for active users: any authenticated request (including `WS /sync` auth) on a session with fewer than 15 days left pushes its `expires_at` back to now + 30 days, keeping the same token. Expired sessions are rejected with 401 and never renewed.

## Passwordless sharing (device keys + invites)

New people never pick a username or password. Each phone holds a P-256 key (Secure Enclave on device).

1. A parent calls `POST /families/invites` `{ "role": "parent"|"caregiver", "access_hours"? }` → `{ id, secret, expires_at, endpoints, family_name, child_name }`. Invites are single use and expire after 72 h; only the SHA-256 of `secret` is stored. `GET /families/invites` lists pending ones, `DELETE /families/invites/{id}` revokes.
2. The app wraps that into `benito://join?p=<base64url JSON>` and sends it by Messages, AirDrop, QR or SharePlay.
3. The joiner's app tries each endpoint's `/health`, then calls `POST /invites/redeem` `{ "invite_id", "secret", "name", "public_key", "device_name"?, "model"? }` → `{ token, user, family }`. `public_key` is standard base64 of the X9.63 uncompressed key.
4. Later sessions: `POST /auth/device/session` with a signature over `benito-device-auth:v1:<device_id>:<unix_ts>` returns a normal bearer token. `POST /auth/device/signup` creates a key-only account (no family yet).
5. `GET /families/members` lists people with role, `access_until` and last seen; `DELETE /families/members/{id}` removes someone (parents only) and ends their sessions.

`caregiver` can log everything but can't invite or remove people, and loses access at `access_until` when one was set. Email/password accounts keep working unchanged; a signed-in app also registers its device key so a lapsed session renews without the password. `GET /server/info` returns the server's name and public URLs for onboarding.

## Useful endpoints

- `GET /health`
- `POST /auth/register`, `POST /auth/login`
- `GET /me`, `DELETE /me`
- `POST /families`, `POST /families/join`, `POST /families/leave`, `POST /families/pairing-tokens`, `POST /families/pair`
- `GET/POST /children`
- `POST/GET /events`, `PATCH/DELETE /events/{id}`, `GET /timeline` (`?child_id=&limit=&since=`, see below)
- `GET /state?child_id=`
- `POST/GET /timers`, `PATCH /timers/{id}` (move an active timer's start), `POST /timers/{id}/pause`, `POST /timers/{id}/resume`, `POST /timers/{id}/stop` (stopping a `sleep` / `feed_breast` timer also inserts the matching event; see below)
- `GET /export` (JSON bundle)
- `GET /export.csv` (pediatrician-friendly event CSV)
- `GET /summary/daily?child_id=&day=YYYY-MM-DD` (or `from`/`to` RFC3339)
- `POST /families/invite/rotate` (invalidate old invite code)
- `POST/DELETE /live-activity/tokens` — ActivityKit update push tokens (see below)
- `WS /sync` — live family fan-out (see below)

Optional HTTP header `X-Client-Id` is echoed on sync envelopes so peers can de-dupe their own writes.

## Change feed (`since=`)

`GET /events` and `GET /timeline` accept an optional `since` (RFC3339, any offset — `Z` or `+00:00`, fractional seconds OK; percent-encode `+` as `%2B`).

| `since` | Returns |
|---|---|
| absent | non-deleted events, `started_at DESC` (normal listing) |
| present | every event with `updated_at > since`, **including soft-deleted tombstones** (`deleted_at` set), ordered `updated_at ASC, id ASC` |

`limit` defaults to 100, clamped to 1..=500. Scoping is unchanged: `child_id` must belong to the caller's family (else 401); without `child_id` the feed covers all of the caller's family's children. An unparseable `since` → 400.

Clients catch up by storing the max `updated_at` they have applied as a cursor and paging `GET /events?child_id=…&since=<cursor>` until a page comes back shorter than `limit`. `WS /sync` stays live-only; run catch-up on connect, reconnect, and foreground.

## Editing events

`PATCH /events/{id}` takes any of `subtype`, `started_at`, `ended_at`, `amount_value`, `amount_unit`, `side`, `notes`, `payload_json`; omitted (or `null`) fields keep their current value. When the request sets `started_at` or `ended_at`, the resulting span is validated against the stored row before anything is written:

- resulting `ended_at` earlier than resulting `started_at` → 400
- new `started_at` more than 5 minutes in the future → 400

Unknown or deleted id → 404; an event outside the caller's family → 401. Success returns the updated event and broadcasts `event.upsert`. `DELETE /events/{id}` soft-deletes (tombstone in the `since=` feed) and broadcasts `event.delete`.

## Timers (pause / resume)

A timer's `state` is `running`, `paused`, or `stopped`. "Active" means `running` **or** `paused`: `GET /state` returns it as `active_timer` and `GET /timers` lists only active timers.

Timer JSON carries `paused_at` (RFC3339 start of the pause in progress, else `null`) and `paused_seconds` (total seconds of **completed** pauses; the open pause is `now - paused_at`). Elapsed active time = `(paused_at ?? now) - started_at - paused_seconds`.

**Phone clock is the authority for timer wall times.** `POST /timers` and `POST /timers/{id}/pause|resume|stop` accept optional `at` (RFC3339). When present, the server stores that value as `started_at` / `paused_at` / `stopped_at` (and uses it when folding pause duration) instead of `Utc::now()`. Clients send device `Date()` so in-app `Date()` / `TimelineView` elapsed starts near `0:00` without a skew offset. `updated_at` remains server time. Multi-device sync assumes phones are roughly NTP-aligned; a phone whose clock differs from the one that started the timer will see a small elapsed offset. `at` more than 5 minutes ahead of the server or more than 24 hours behind → 400. Omitting `at` keeps the old server-clock behavior (tests / older clients). On the macOS LaunchAgent host, re-run `scripts/macos-service.sh install` after pulling these server changes — `restart` alone keeps the old binary.

| request | from state | result |
|---|---|---|
| `POST /timers` `{"child_id","kind","side"?, "at"?}` | — | 200 timer; `started_at` = `at` or server now |
| `PATCH /timers/{id}` `{"started_at": RFC3339, "at"?}` | `running` / `paused` | 200 timer with the new `started_at`. Optional `at` is the phone's now for the future/24h checks (not stored); omit it to compare against server time |
| `POST /timers/{id}/pause` `{"at"?}` | `running` | 200 timer, `state: "paused"`, `paused_at` = `at` or server now |
| `POST /timers/{id}/resume` `{"at"?}` | `paused` | 200 timer, `state: "running"`, `paused_seconds += at - paused_at`, `paused_at: null` |
| `POST /timers/{id}/stop` `{"at"?}` | `running` / `paused` | 200 timer, `state: "stopped"`; an open pause is folded into `paused_seconds` first |
| `POST /timers/{id}/stop` | `stopped` | 200 timer unchanged (idempotent, no new event) |

Pause from a non-`running` state or resume from a non-`paused` state → 409 (`{"error": "timer is not running"}` / `"timer is not paused"`). Unknown id → 404; a timer outside the caller's family → 401. Pause, resume, and start adjustment broadcast `timer.upsert`; stop broadcasts `timer.stop`.

`PATCH /timers/{id}` fixes "forgot to start it 10 minutes ago": a stopped timer → 409 (`"timer is not active"`); `started_at` more than 1 minute ahead of `at` (or server now if `at` is omitted), more than 24 hours before that same reference, or (for a paused timer) later than `paused_at` → 400. `at` itself follows the same 5-minute-future / 24-hour-past slack as other timer actions. The event auto-created on stop uses the adjusted start. Clients should send device `Date()` as `at` so a phone clock ahead of the server can still set the start to "now".

The `sleep` / `feed_breast` event created on stop keeps the wall-clock span (`started_at` = timer start, `ended_at` = stop time) and gets `payload_json: {"paused_seconds": N}` when N > 0 (else `null`). Active duration = `ended_at - started_at - paused_seconds`; `GET /summary/daily` `sleep_hours` subtracts it.

## WebSocket sync protocol

Endpoint: `WS /sync` (or `WS /sync?token=...`).

Envelope JSON:

```json
{ "type": "...", "payload": { }, "at": "2026-09-26T01:00:00.000000000Z", "client_id": "optional" }
```

### Client → server

1. First message (unless `?token=` was used):

```json
{ "type": "auth", "payload": { "token": "<session>", "client_id": "<stable-id>" } }
```

2. Optional: `{ "type": "ping" }` → server replies `pong` to the family channel.
3. Optional: `{ "type": "refetch_state", "payload": { "child_id": "..." } }` → family gets `state` with `action: "refetch"`.

### Server → client

| type | when |
|---|---|
| `hello` | after successful auth (`payload` includes `family_id`, `user_id`, `client_id`) |
| `error` | auth failure / bad client message |
| `event.upsert` | event created/updated (full event object in `payload`) |
| `event.delete` | soft-delete (`payload`: `{ id, child_id }`) |
| `timer.upsert` | timer started / paused / resumed |
| `timer.stop` | timer stopped |
| `state` | hint to refetch `GET /state?child_id=` (`payload.action` usually `refetch`) |
| `pong` | response to ping |

Broadcast is **family-scoped**: every authenticated WS client in the same family receives mutations (including the originating client). Multi-instance deploys will need Redis (or similar) later; a single SQLite process is fine for v1.

### Smoke test

```bash
cd server
cargo test --test sync_smoke -- --nocapture
cargo test --test catch_up    # since= change feed
cargo test --test pause_resume
```

Manual: register two users, create/join family, open `websocat ws://127.0.0.1:8080/sync`, send auth, create an event via HTTP with the other token, watch `event.upsert`.

## Docker

From repo root (requires Docker Engine + Compose):

```bash
export SESSION_SECRET="$(openssl rand -hex 32)"
docker compose up --build
curl -sf http://127.0.0.1:8080/health
```

Data persists in the `benito-data` volume at `/data/data.db`.

If `docker` is not installed: `sudo apt-get install -y docker.io docker-compose-v2` (Debian/Ubuntu) or equivalent — needs root. Leave `docker-compose.yml` unchanged when Docker is unavailable on the build host.

See also `docs/deploy-tailscale.md` and `docs/deploy-vps.md`.

## Phone access (Tailscale Serve)

The server binds loopback by default. Put TLS in front of it on the same host so iOS ATS is satisfied without exceptions:

```bash
cargo run --release   # listens on 127.0.0.1:8080
tailscale serve --bg --https=443 http://127.0.0.1:8080
```

Then point the app at `https://<machine>.<tailnet>.ts.net`. A reverse proxy (Caddy, nginx) with a real certificate works the same way. Set `BIND_ADDR=0.0.0.0:8080` only if something off-host must reach the plain-HTTP port directly. More detail: `docs/deploy-tailscale.md`, `docs/phone-server.md`.
