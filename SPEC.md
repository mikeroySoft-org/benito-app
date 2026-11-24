# Benito — Product & technical spec

**Repo:** [mikeroysoft-org/benito-app](https://github.com/mikeroysoft-org/benito-app)  
**Canonical intent:** the original design issue (body + Revision 1 comment, 2026-09-25)  
**Status:** Spec locked for implementation (six open questions resolved 2026-09-25 PT)  
**Child in scope for v1:** one newborn (0–2 months)  
**License:** MIT

---

## Principles

- Good **open-source** software for our family and anyone who self-hosts — not a business, brand, or growth funnel.
- **No** paid app, IAP, or subscription for the software.
- **No** multi-tenant SaaS “just to monetize.” The sync server is infrastructure **you** run.
- Fame / commercialization are non-goals. Correctness, privacy, and two-parent UX are the goals.

---

## Locked decisions (2026-09-25)

| # | Topic | Decision |
|---|---|---|
| 1 | Server stack | **Rust (axum) + SQLite** — one binary, one DB file |
| 2 | v1 reminders | **Local notifications only**; APNs partner pings in v1.1 |
| 3 | Local store | **GRDB** (explicit SQL, sync-queue friendly) |
| 4 | Distribution | ~~Source-only for now~~ **Revised 2026-11-17 (Revision 2):** signed, notarized binaries for the Mac server app; source is MIT licensed, and the repository goes public before the first release. iPhone app: build from source until TestFlight/App Store |
| 5 | Exposure | **Document both** home Tailscale and public HTTPS |
| 6 | License | **MIT** |

---

## Why this exists

Huckleberry’s logging core is good, but:

- Useful extras sit behind Plus (~$69/yr) or Premium (~$120/yr).
- “Sharing” is both parents signing into **one shared account** (their FAQ).
- Data lives in their cloud; no self-host; ad-tracking privacy label.

**Benito:** MIT open source, one Docker deploy, **two real user accounts** with live sync, full export anytime.

---

## What matters to replicate (from Huckleberry research)

| Keep / beat | Defer / skip |
|---|---|
| Fast one-touch logging | SweetSpot-class ML as a v1 moat |
| Real two-parent identity + sync | Berry AI chat |
| Shared running timers | Expert sleep plans / consults |
| Daily pediatrician-style summaries | Android / public web app for now |
| Later: wake-window predictions (v2) | Medical claims, social features |

---

## Product requirements

### v1 (MVP) — newborn months

> Implementation note: scaffold and early PRs prioritize **v1a** (feed / diaper / sleep / shared timers / two accounts / export). Schema still includes medicine / temperature / growth / etc. from day one.

Target: feed, diaper, sleep, and “how many wet diapers?” for pediatrician visits. Predictions wait until 2+ months.

1. **Two parents, two accounts, one baby.** Accounts paired by invite code or in person over SharePlay/AirDrop (short-lived single-use pairing token); live sync. Headline gap vs Huckleberry.
2. **One-touch event logging**
   - Feeding: breast (L/R, running timer), bottle (amount, milk type), solids (food, reaction)
   - Diaper: wet / dirty / both (+ contents notes: color, consistency)
   - Sleep: nap or night; timer or manual
   - Pumping: side, amount, duration
   - Medicine (name, dose), temperature, growth (weight/height/head)
   - Free-text notes; custom event categories
3. **Shared timers.** Timer started on one phone is live on the other; either parent (or Watch) can stop it. Server-authoritative timer state. Live Activities / Dynamic Island on lock screen.
4. **“State of the baby” home glance:** time since last feed + side, last diaper + contents, asleep/awake + duration, last medicine.
5. **History + daily summary:** feeds, ounces, wet/dirty counts, sleep hours — pediatrician-ready.
6. **Reminders:** feeding / medication via **local notifications** in v1. APNs partner pings wait for v1.1.
7. **Export:** full JSON/CSV anytime.
8. **Multiple children** in the data model from day one (UI for extras can lag).

### Platform (Revision 1 — supersedes PWA)

- **Native Swift/SwiftUI:** iPhone + iPad first, **watchOS** companion.
- One multiplatform Xcode project + shared Swift package (models, sync, API client).
- PWA / Android / web clients: out for now. API stays platform-agnostic.
- Unlocks: Live Activities, Watch + complications, widgets, App Intents / Shortcuts, APNs in v1.1+.

### Mac server app (Revision 2, 2026-11-17)

- **Benito Server** for Mac: a menubar app that installs, runs and looks after `benito-server` (status, backups and restore, people and devices, invites by QR, logs, updates). Plan: [`docs/plans/mac-server-app.md`](./docs/plans/mac-server-app.md).
- It is an admin tool, not a client. Baby data appears only as a read-only glance; logging stays on iPhone, iPad and Watch.
- No separate native Mac client. The iPhone/iPad app runs on Apple Silicon Macs as "Designed for iPad".
- Shipped as a Developer ID signed, notarized DMG with Sparkle updates. Building from source stays supported; Docker and `scripts/macos-service.sh` remain for Linux, NAS and headless hosts.

### v1.1

- APNs partner-activity pings
- Home/lock-screen widgets
- App Intents / Siri

### v2 (2+ months)

- Wake-window engine (age table + baby’s own patterns) — replaces SweetSpot
- Day schedule from wake windows
- Trend charts (sleep/feeding/growth)

### v3

- Huckleberry import (if usable export exists)
- Optional self-hosted AI logging/chat

### Non-goals

- Sleep-training plans, expert consults, medical-adjacent advice
- App Store as a **business**; a free TestFlight/App Store install path for the iPhone app can come later (the Mac server app ships as a signed download, see Revision 2)
- Social/community features, growth-percentile medical claims
- CloudKit as primary sync (rejected: Apple cloud custody, paid-dev friction for OSS users, no server-side reminders / future non-Apple clients)

---

## Architecture

### Backend

- Self-hosted **one small service** in Docker.
- **Rust (axum) + SQLite** — one binary, one DB file. Backups are built into the server (SQLite online backup, integrity-checked, pruned); restore is a server subcommand.
- A loopback-only **admin API** on its own port (off by default) serves the Mac server app: status, people and devices, invites, backups. It is never reachable through Tailscale Serve, the LAN listener or a reverse proxy.
- Sync: WebSocket (or equivalent) for live events/timers; append-oriented events; edits last-writer-wins on `updated_at`.
- Auth: two users + invite code; session tokens. Sign in with Apple optional polish, not required.
- Notifications: local on-device for v1 reminders; APNs for partner pings in v1.1+.
- Deploy: Dockerfile + compose, one volume. Document **both** Tailscale-only home deploy and public HTTPS (VPS / reverse proxy).

### Client

- Local-first store + sync queue: **GRDB**.
- Offline queue; push when server reachable.
- Watch via WatchConnectivity and/or direct to server when standalone.

### Data model sketch

```
users(id, name, created_at)
families(id, invite_code)
family_members(family_id, user_id, role)
children(id, family_id, name, birthdate, sex)
events(id, child_id, type, subtype, started_at, ended_at,
       amount_value, amount_unit, side, notes, payload_json,
       created_by, created_at, updated_at, deleted_at)
timers(id, child_id, kind, started_at, started_by, state)
reminders(id, child_id, kind, rule, next_fire_at)
push_subscriptions(user_id, endpoint, keys_json)  -- v1.1+ APNs
```

v1 event types: `feed_breast`, `feed_bottle`, `feed_solid`, `diaper`, `sleep`, `pump`, `medicine`, `temperature`, `growth`, `milestone`, `note`, `custom`.

### API sketch

`POST/PATCH/DELETE /events`, `GET /timeline`, `GET /state` (home glance), `POST /timers`, `POST /timers/:id/stop`, `POST /reminders`, `GET /export`, `WS /sync`.

---

## Sources

- The original design issue + Revision 1 comment (2026-09-25)
- Locked decisions confirmed in chat 2026-09-25 PT
- Huckleberry product/pricing/help + App Store listing (research keep-copies under workspace `baby-tracker/` during drafting)
