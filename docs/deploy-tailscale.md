# Deploy at home (Mac / NAS / Pi) with Tailscale Serve HTTPS

Run Benito on a machine at home, keep it bound to loopback, and let **Tailscale Serve** put a real HTTPS certificate in front of it. No public ports, no router port-forwarding, and the same URL works on home Wi‑Fi and on cellular.

```text
iPhone (Tailscale app) ──HTTPS/WSS over tailnet──▶ tailscale serve :443 ──HTTP──▶ 127.0.0.1:8080 benito-server
```

## Prerequisites

- A host that stays on: Mac, NAS, Raspberry Pi, mini PC, etc.
- [Tailscale](https://tailscale.com/) installed and logged in on that host.
- The Tailscale app on **every parent phone**, either signed into the same tailnet or with the server node [shared](https://tailscale.com/kb/1084/sharing) to the partner's Tailscale account. A phone that is not on the tailnet cannot reach the server.
- In the [tailnet admin console](https://login.tailscale.com/admin/dns): enable **MagicDNS** and **HTTPS Certificates**.

## 1. Run the server on loopback

On a Mac that should serve the family around the clock, install it as a launchd service instead (starts at login, restarts on crash, nightly backups): see [`deploy-macos.md`](./deploy-macos.md).

Otherwise, the foreground helper script (builds with cargo, or runs `server/target/release/benito-server` if present):

```bash
./scripts/run-server.sh      # BIND_ADDR defaults to 127.0.0.1:8080
```

or Docker Compose from the repo root:

```bash
export SESSION_SECRET="$(openssl rand -hex 32)"
docker compose up -d --build
```

Compose publishes only on `127.0.0.1:${BENITO_PORT:-8080}` (the container itself listens on `0.0.0.0:8080` internally). Data lives in the `benito-data` volume (`/data/data.db` in the container). Put `SESSION_SECRET` in a repo-root `.env` (gitignored; see `.env.example`) or use `SESSION_SECRET_FILE` so it survives restarts.

Check it locally:

```bash
curl -sf http://127.0.0.1:8080/health
```

## 2. Turn on Tailscale Serve (one time)

```bash
tailscale serve --bg --https=443 http://127.0.0.1:8080
```

On Linux you may need `sudo` (or run `sudo tailscale set --operator=$USER` once). `--bg` makes the config persistent across reboots and Tailscale restarts. Inspect or undo it with:

```bash
tailscale serve status
tailscale serve --https=443 off
```

Serve provisions and renews a Let's Encrypt certificate for the node's MagicDNS name automatically; the very first HTTPS request can take a few seconds while the certificate is issued.

Do **not** use `tailscale funnel` — that exposes the server to the public internet.

## 3. Verify

From any device on the tailnet:

```bash
curl -sf https://<machine>.<tailnet>.ts.net/health
```

`tailscale status --json` shows the exact name under `Self.DNSName` (drop the trailing dot); `./scripts/run-server.sh` prints it at startup.

## 4. Point the app at it

In Benito, set **Server URL** to the HTTPS origin, with no port and no trailing slash required:

```text
https://<machine>.<tailnet>.ts.net
```

The app opens with an empty Server URL on first launch. The same URL works on home Wi‑Fi and on cellular, as long as the phone's Tailscale VPN is connected. The live-sync WebSocket (`/sync`) goes through Serve too, as `wss://`.

See [`phone-server.md`](./phone-server.md) for the device checklist.

## Privacy note

HTTPS certificates are recorded in public [Certificate Transparency](https://tailscale.com/kb/1153/enabling-https) logs, so the full hostname (machine name **and** tailnet name) becomes publicly visible. Nothing is reachable from outside the tailnet, but choose machine and tailnet names you don't mind being public.

## Backup

Copy the SQLite file:

```bash
docker compose exec benito ls -la /data
# or stop briefly and copy the volume bind/path you configured
```

Backup = file copy of `data.db` (and `-wal`/`-shm` if present while running; prefer stop or `sqlite3 .backup`).

The macOS launchd service takes integrity-checked nightly backups automatically; see [`deploy-macos.md`](./deploy-macos.md#backups).

## Notes

- v1 reminders are **local notifications** on each phone — Tailscale only needs to reach the API for sync/timers.
- Do not commit `SESSION_SECRET` or `*.db` into git.
