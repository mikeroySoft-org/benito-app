# Benito

A free, open-source baby tracker for iPhone, iPad and Apple Watch, with a small sync server you run yourself. Log feeds, sleep and diapers, share live timers, and invite your partner, grandparents or a babysitter without anyone making an account.

- **Free and open source** ([MIT](./LICENSE)). No ads, no in-app purchases, no analytics, no company.
- **Your data stays home.** One Rust binary and one SQLite file on a Mac, a Raspberry Pi, a NAS or a VPS.
- **Real sharing.** Every phone in the family sees the same timeline and running timers within a second.
- **No passwords for family.** Account › Sharing › **Invite to Family**, then send the invite by Messages, AirDrop, a QR code or SharePlay. Each phone gets its own key, kept in the Secure Enclave.
- **Babysitter-friendly.** Caregiver invites can end after a few hours or days, and someone on your home Wi-Fi doesn't need Tailscale or a VPN.

Product decisions live in [SPEC.md](./SPEC.md).

## Self-host in ten minutes

### 1. Run the server

On a Mac, download **[Benito Server](https://github.com/mikeroySoft-org/benito-app/releases/latest)**, drag it to Applications, open it and choose **Install Server**. It lives in the menu bar, keeps the server running, backs it up, makes invites and updates itself (macOS 14 or later).

Or from the terminal on a Mac (keeps running in the background, with nightly backups):

```bash
git clone https://github.com/mikeroysoft-org/benito-app && cd benito-app
scripts/macos-service.sh install      # builds, generates a session secret, starts at login
curl -s http://127.0.0.1:8080/health
```

Details: [docs/deploy-macos.md](./docs/deploy-macos.md).

With Docker (Linux, NAS):

```bash
export SESSION_SECRET="$(openssl rand -hex 32)"
docker compose up -d --build
curl -s http://127.0.0.1:8080/health
```

Or straight from source: `cd server && cargo run --release`. All settings are listed in [server/README.md](./server/README.md).

### 2. Make it reachable from phones

Pick one or both:

| Who | How | Guide |
|---|---|---|
| Everyone, anywhere (recommended) | [Tailscale Serve](https://tailscale.com/kb/1312/serve) gives you an HTTPS URL on your tailnet | [docs/deploy-tailscale.md](./docs/deploy-tailscale.md) |
| Anyone on your home Wi-Fi, such as a babysitter | Add a LAN listener and tell invites about it (`BENITO_LAN_PORT=8081` plus `BENITO_PUBLIC_URLS=http://<mac-ip>:8081,https://<host>.<tailnet>.ts.net` in `benito.env` on a Mac; `BIND_ADDR=127.0.0.1:8080,0.0.0.0:8081` elsewhere) | [docs/deploy-macos.md](./docs/deploy-macos.md#home-wi-fi-without-tailscale) |
| The public internet | A VPS behind Caddy or nginx with TLS | [docs/deploy-vps.md](./docs/deploy-vps.md) |

The LAN listener is plain HTTP, so only enable it on a network you trust (see [SECURITY.md](./SECURITY.md)). When it's on, the server advertises itself over Bonjour, and the app finds it during setup.

### 3. Install the app

Benito isn't on the App Store yet, so build it with Xcode 16 or later:

```bash
brew install xcodegen
cp apps/Benito/Config/Local.xcconfig.example apps/Benito/Config/Local.xcconfig
# edit Local.xcconfig: your Apple Developer team id, a bundle prefix you own, your child's name for Siri
cd apps/Benito && xcodegen generate && open Benito.xcodeproj
```

Run the **Benito** scheme on your iPhone. On first launch the app walks you through it: choose your server (found automatically on your Wi-Fi, or paste the URL), name your family and child, and you're in. Short tips point out timers, the timeline and sharing the first time you see them.

### 4. Invite your family

Account › **Sharing** lists everyone who can see your baby's data, with pending invites. Tap **Invite to Family**, choose *Parent* or *Caregiver* (with an optional end time), and send it by Messages, AirDrop, QR code or SharePlay. The other person opens the link, types their name, and they're in. Swipe left on anyone to stop sharing with them.

Each invite works once and expires after three days.

## Repository layout

```text
SPEC.md                 product and technical decisions
server/                 Rust sync server (axum + SQLite)
apps/Benito/            iPhone and iPad app (SwiftUI, XcodeGen)
apps/BenitoServer/      Mac menubar app that installs and looks after the server (releases: docs/release-mac.md)
apps/BenitoWatch/       Apple Watch app
apps/BenitoWidgets/     widgets and Live Activities
packages/BenitoKit/     shared Swift package: models, API client, local store
docs/                   deploy guides and design notes
scripts/                service install, backups, dev helpers
```

More app details: [apps/README.md](./apps/README.md). Phone networking notes: [docs/phone-server.md](./docs/phone-server.md).

## Contributing

Issues and pull requests are welcome. Start with [CONTRIBUTING.md](./CONTRIBUTING.md), and please follow the [Code of Conduct](./CODE_OF_CONDUCT.md). Report security problems privately as described in [SECURITY.md](./SECURITY.md).
