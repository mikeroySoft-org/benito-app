# Phone ↔ Benito server (real device)

Physical iPhones talk to Benito over **HTTPS** — at home that means the Tailscale Serve URL:

```text
https://<machine>.<tailnet>.ts.net
```

Setup (MagicDNS + HTTPS certificates, `tailscale serve`, verification) lives in [`deploy-tailscale.md`](./deploy-tailscale.md). A public VPS behind Caddy/nginx works the same way with `https://benito.example.com` ([`deploy-vps.md`](./deploy-vps.md)).

## Run the server

On the home server machine:

```bash
./scripts/run-server.sh
# or: docker compose up -d --build
curl -sf http://127.0.0.1:8080/health
curl -sf https://<machine>.<tailnet>.ts.net/health    # through Tailscale Serve
```

The server binds `127.0.0.1:8080`; it is not reachable on the LAN directly. The script prints the Serve URL (from `tailscale status --json`) and the one-time `tailscale serve --bg --https=443 http://127.0.0.1:8080` command. Set `SESSION_SECRET` via repo-root `.env` (gitignored; see `.env.example`) or `SESSION_SECRET_FILE`. Sessions are DB tokens — rotating the secret does not log phones out.

## Point the iPhone at the server

1. Install the Tailscale app on the phone and connect it to the tailnet (or accept the shared server node).
2. Install/run Benito on the phone (Xcode → physical device).
3. On first launch the **Server URL** field is empty — enter `https://<machine>.<tailnet>.ts.net`.
4. Register or sign in. The session is kept in the Keychain per server URL, so relaunching the app stays signed in; switching the URL uses that server's own session.
5. The same URL works on home Wi‑Fi and on cellular while Tailscale is connected.

## ATS / cleartext

`Info.plist` sets only:

- `NSAllowsLocalNetworking` = true
- `NSLocalNetworkUsageDescription`
- `NSBonjourServices`

There are **no** per-host `NSExceptionDomains`. App Transport Security ignores IP-literal exception keys (e.g. a `192.168.x.y` or `100.x.y.z` entry is a no-op), so per-IP cleartext exceptions never worked reliably for LAN or Tailscale IPs.

Plain HTTP is for development only:

| Situation | Server URL |
|-----------|------------|
| Simulator + server on the same Mac | `http://127.0.0.1:8080` (the Simulator preset button fills this in; allowed by `NSAllowsLocalNetworking`) |
| Physical device, home or away | `https://<machine>.<tailnet>.ts.net` (Tailscale Serve) |
| Physical device, public deploy | `https://benito.example.com` (reverse proxy with TLS) |

`NSAllowsLocalNetworking` also permits cleartext to unqualified names and `.local` hosts, but the supported device path is HTTPS.

## Smoke checklist

1. Server host: `curl -sf http://127.0.0.1:8080/health`
2. Any tailnet device: `curl -sf https://<machine>.<tailnet>.ts.net/health`
3. Phone: Server URL set → Register or Login
4. Create family → note invite code → second device Join
5. Log diaper / start sleep timer on phone A → see on phone B via sync (`wss://…/sync`)
6. Background phone B, log on phone A, foreground phone B → history catches up
7. Airplane mode → log → reconnect → outbox flushes
8. `GET /summary/daily?child_id=…&day=YYYY-MM-DD` (or `from`/`to`) for pediatrician totals
9. `GET /export.csv` for spreadsheet paste
10. `POST /families/invite/rotate` if an invite code was shared too widely

## Device logs

Stream OSLog while the phone talks to the server: [`device-logs.md`](./device-logs.md) (`./scripts/stream-device-logs.sh`, subsystem `com.mikeroysoft.benito`).

## Timer clocks

Feed / sleep timers treat the **phone wall clock** as source of truth for elapsed display. Start, pause, resume, and stop send device `Date()` as `at`; the server stores those timestamps on the timer (`started_at` / `paused_at` / `stopped_at`). Multi-device sync still works when phones are NTP-synced; see `server/README.md` (Timers).

**Deploy note (macOS LaunchAgent):** committing phone-`at` server code is not enough — the running binary must be rebuilt and swapped with `scripts/macos-service.sh install`. A stale LaunchAgent still overwrites starts with server `Utc::now()`, so a phone ~50s ahead shows Feed/Sleep clocks starting near `0:50`. After pull: `install` → `curl -sf http://127.0.0.1:8080/health` → start a timer and confirm `started_at` matches the phone `at` (not server now).

