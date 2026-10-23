# Plan: open source + App Store readiness, first-run onboarding, passwordless sharing

Status: in progress on `feat/oss-onboarding-sharing` (2026-10-23).
Stance: free and open source. No IAP, no paid tier, no analytics, no SaaS.

## 0. Defaults chosen (change any of them by editing this file)

| Topic | Default | Why |
|---|---|---|
| License | **Keep MIT** (already in `LICENSE` and `Cargo.toml`) | Already published as MIT; App Store compatible. Apache-2.0 adds a patent grant; switching is Michael's call (decision D1). |
| Identity | Per-device P-256 key (Secure Enclave when available, Keychain-only fallback on Simulator) | No usernames or passwords for new people. |
| Auth exchange | Device signs `benito-device-auth:v1:<device_id>:<unix_ts>`; server returns a normal bearer session | Every existing endpoint, the WebSocket and older app builds keep using bearer tokens unchanged. |
| Existing accounts | Email/password stays. A signed-in app quietly registers its device key (`POST /devices`), so a lapsed session renews with the key instead of the password | Existing password accounts keep working, and migrate on first launch of the new build. |
| Invite transport | `benito://join?p=<base64url JSON>` custom scheme (Text, AirDrop/share sheet, QR, SharePlay messenger) | Universal links need a domain with `apple-app-site-association` (decision D4). |
| Invite lifetime | 72 h, single use, secret stored hashed (SHA-256) | Covers "text it tonight, babysitter opens it tomorrow". |
| Roles | `parent` (full) and `caregiver` (logs everything; can't invite, revoke or rotate; optional access end date) | Babysitter use case. It was cheap, so it's implemented. |
| Endpoints in invite | The inviter's current server URL, plus `BENITO_PUBLIC_URLS` from the server env | The joiner probes `/health` in order and keeps the first that answers. A babysitter on home Wi-Fi never needs Tailscale. |
| LAN listener | `BIND_ADDR` accepts a comma list, such as `127.0.0.1:8080,0.0.0.0:8081` | Lets LAN clients in without changing the Tailscale Serve setup. Turning it on at home is decision D3. |
| LAN discovery | Server advertises `_benito._tcp` over Bonjour (`dns-sd` on macOS, `avahi-publish` on Linux) when bound beyond loopback. The app browses with `NWBrowser` during onboarding | No new crates. |
| LAN TLS | Plain HTTP on the LAN for now. ATS allows it via `NSAllowsLocalNetworking` and IP literals. No password crosses the wire because device keys sign. **Proposal:** the server generates a self-signed cert and the invite carries its SPKI SHA-256 pin. The app pins in a `URLSessionDelegate` for LAN endpoints only | Bearer tokens are still in clear on the LAN until pinning ships (decision D5). |
| Local-only mode | **Scoped, not built.** Shown in onboarding as "Coming soon" | See section 4. It's the App Review blocker (decision D2). |
| Tips | TipKit, `displayFrequency(.immediate)`, invalidated on first use. Account has "Show tips again" | Shows once, and can be reset for testing. |

## 1. OSS / App Store readiness

- Audited before publishing: no secrets; personal identifiers removed. This repository starts from a single squashed commit.
- Personal values move from the tree to config:
  - `DEVELOPMENT_TEAM`, `BENITO_SIRI_NAME` and the bundle prefix go to `apps/Benito/Config/Local.xcconfig`, which is gitignored. A template sits next to it.
  - The child's name is removed from sources, docs and tests.
  - LAN and tailnet IPs and home paths are scrubbed from docs.
- New files: README with a self-host guide, CONTRIBUTING, CODE_OF_CONDUCT (Contributor Covenant 2.1), SECURITY, PR and issue templates, and `.github/workflows/ci.yml`. CI runs on `macos-15`: xcodegen, xcodebuild for the Simulator, the timer-chrome lint, `cargo test`, and `swift test` for BenitoKit.
- Onboarding gets a server URL step, with Bonjour discovery and a manual entry field.
- Nothing is made public or submitted. GitHub visibility is unchanged.

## 2. First-run onboarding (TipKit)

`OnboardingFlow` is shown when the app is not signed in and `benito.onboarding.done` is false. Existing signed-in users never see it.

1. **Welcome:** icon, one line, "Get started".
2. **Choose:** Create a family / Join a family / Use on this device only (Coming soon).
3. **Create:**
   1. Server step: discovered `_benito._tcp` servers, or type a URL, then test `/health`.
   2. Your name, family name, baby's name.
   3. `POST /auth/device/signup`, then `POST /families`.
4. **Join:** open or paste the invite link (a link opened from Messages or AirDrop skips this screen). "Sign in with email" remains for existing accounts.

Tips: Start a feed (Home Feed button), Log a diaper (Home Diaper button), Timeline Day mode, Siri shortcuts, and Sharing (Account → Sharing).

## 3. Passwordless sharing

Server tables (migration 006 only adds things):
- `devices`: id, user_id, public_key, name, model, last_seen_at, last_auth_ts, revoked_at.
- `family_invites`: id, family_id, secret_hash, role, access_hours, created_by, expires_at, used_*, revoked_at.
- `family_members.expires_at`: added column.
- `sessions.device_id`: added column.
- `server_meta`: holds `server_id`.

Endpoints:
- `GET /server/info`: public. Returns server_id, version and advertised URLs.
- `POST /auth/device/signup`: name and public key, returns a session.
- `POST /auth/device/session`: device id, timestamp and signature, returns a session.
- `POST /devices`: authed. Adds a key to an existing account (migration path).
- `GET /families/members`: members with role, devices, last seen and access end.
- `DELETE /families/members/{user_id}`: parents only. Removes the membership, deletes sessions and revokes devices.
- `POST /families/invites` and `GET /families/invites`: parents only.
- `DELETE /families/invites/{id}`.
- `POST /invites/redeem`: unauthenticated. Takes the invite id and secret, a display name and a device key. Creates the user, device, membership and session in one transaction. If a bearer token is sent and that user has no family, the existing account is used instead.

Passwordless users get an unusable password hash and a synthetic `<uuid>@device.benito.invalid` email. That keeps the `users` table unchanged, so older builds and a rolled-back server still work.

App side:
- Account → **Sharing**: lists members (name, role, devices, last seen), lets a parent swipe to remove someone, and lists pending invites.
- **Invite to Family** sheet: pick a role (and access length for caregivers), then Text (`sms:` compose with the link), AirDrop/Share (`ShareLink`), SharePlay, or a QR code.
- SharePlay was redone. The joiner no longer has to be signed in or on the same server URL. Approval sends the invite link over `GroupSessionMessenger`, and the joiner redeems it through the same code path as a texted link.
- Root cause of the old failure: `prepareInvite()` ran again on every `onAppear`, which minted a new `inviteID`. When the share sheet closed, the inviting phone no longer recognized its own session and treated itself as the joiner ("already in a family").

## 4. Local-only mode (scoped, not built)

The app is server-centric: timers, `/state` and summaries come from the server, and only events are cached in GRDB.

To run with no server, the app needs a `LocalBackend` behind the same calls `AppModel` uses:
- timers table and state in GRDB;
- summary computed locally (there's already a local fallback for fed and crying totals);
- export from GRDB.

Estimate: 2–3 focused days. A local-only family could later be "promoted" to a server by uploading its GRDB events.

Alternative for App Review: provide a demo server and a reviewer invite link in the review notes. That's faster but needs a public HTTPS host (decision D2).

## 5. Rollout / compatibility

- Migration 006 only adds things, and old app builds ignore the new JSON fields. Deploying the server first is safe.
- Back up `benito.db` before deploying.
- Old SharePlay pairing endpoints stay for older builds. The SharePlay message format changed, so both phones need the new build to pair over SharePlay.
