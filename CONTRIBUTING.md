# Contributing to Benito

Thanks for helping. Benito is a free, self-hosted baby tracker. There is no company, no paid tier and no analytics, and contributions should keep it that way.

## Ground rules

- Open an issue before a large change so we can agree on the shape first. Small fixes can go straight to a pull request.
- [SPEC.md](./SPEC.md) is the product contract. Changes that contradict it need an issue first.
- No tracking, ads, analytics SDKs, or third-party services the user did not choose.
- Never commit secrets, `.env` files, `.p8` keys, `apps/Benito/Config/Local.xcconfig`, or a modified `apps/Benito/Sources/Generated/GitSHA.swift` (the build rewrites it).
- Be kind. See the [Code of Conduct](./CODE_OF_CONDUCT.md).

## Set up

You need a Mac with Xcode 16 or later for the apps, and Rust (stable) for the server.

```bash
# Server
cd server && cargo test && cargo run          # http://127.0.0.1:8080/health

# Shared Swift package
cd packages/BenitoKit && swift test

# Apps
brew install xcodegen
cp apps/Benito/Config/Local.xcconfig.example apps/Benito/Config/Local.xcconfig   # your team id + bundle prefix
cd apps/Benito && xcodegen generate && open Benito.xcodeproj
```

The Simulator build works without a team. Running on a phone needs your own Apple Developer team in `Local.xcconfig`, and an HTTPS server URL or a LAN URL (see [docs/phone-server.md](./docs/phone-server.md)).

## Pull requests

- Keep each PR to one change, with a short description of what and why.
- Add or update tests: `server/tests` for API behavior, `packages/BenitoKit/Tests` for shared logic.
- Run `cargo test`, `swift test`, and `./scripts/check-timer-chrome.sh` before pushing. CI runs the same checks plus a Simulator build.
- SwiftUI: target iOS 18, use `@Observable`, keep views small, and support light and dark mode and Dynamic Type.
- Server: database changes go in a new numbered file in `server/migrations`. Never edit a migration that has shipped. Changes must stay backward compatible with older app builds.

## Factory gate

Run `python -m factory gate` with the factory environment on the native Mac host.
`.factory.toml` runs server and BenitoKit tests, the helper fixture and scratch-server
tests, timer chrome lint, project-generation drift, iOS/watch Simulator builds, and
site tests/plumbing in order. `--tier release` runs the unsigned Release Simulator
build only; signed device builds and archives require the owner's team.

Each check uses `scripts/gate-env.sh` to disable Bonjour and Python bytecode and
set `BENITO_DB=/nonexistent`. Scratch-server tests use a temporary database and a
free loopback port, never the live service. Cold caches need network access.
Run `scripts/check-site-plumbing.sh` separately to check Pages without deploying.

The gate protects signing, deployment, published migrations, service/backup scripts,
its own configuration, and gate helpers (`scripts/gate-env.sh` and
`scripts/check-site-plumbing.sh`). New numbered migrations remain allowed. `SPEC.md` still
requires human review: factory has no nonblocking path-review flag, so it is not
protected. Clippy/fmt cleanup and signed builds are deliberately outside this gate.

## Reporting security problems

Please don't open a public issue. See [SECURITY.md](./SECURITY.md).
