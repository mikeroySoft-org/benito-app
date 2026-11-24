# Notes for AI agents

Benito is a self-hosted baby tracker: SwiftUI iPhone/Watch apps (`apps/`) syncing to a Rust +
SQLite server (`server/`). This file is for agents helping a parent run it, or working on the code.

## Helping a parent (install, operate, answer questions from their data)

Use the portable Agent Skill in [`skills/benito/SKILL.md`](skills/benito/SKILL.md). It covers
installing the server (macOS LaunchAgent, Docker/Linux), backups and upgrades, troubleshooting,
and reading the database with the read-only helper `skills/benito/scripts/benito-query`.

The short version of its rules: read-only by default; never edit the database while the server
runs; back up and ask before any change; keep the data on the user's machine; never read session
tokens or `benito.env`; and send medical questions to the pediatrician.

To install the skill in an agent that supports Agent Skills, copy or symlink `skills/benito/` into
that agent's skills folder.

## Working on the code

- Server: `cd server && cargo test --locked` (set `BENITO_BONJOUR=0` to keep tests off the LAN).
- Skill helper: `python3 skills/benito/tests/test_benito_query.py` (add
  `--server server/target/debug/benito-server` after `cargo build --locked` to cross-check against a
  live scratch server).
- Never run `scripts/macos-service.sh install|uninstall|restart` on a machine whose Benito service
  holds real family data unless that is the task; it replaces the running service.
- Use a scratch database (`DATABASE_PATH=/tmp/...`) and a free loopback port for experiments.
- Mac server app (`apps/BenitoServer`, plan in `docs/plans/mac-server-app.md`):
  `scripts/dev-server-app.sh` builds it and runs it against a scratch server with demo data under
  `$TMPDIR`; it never touches the real install. Build check: `cd apps/BenitoServer && xcodegen
  generate && xcodebuild build -project BenitoServer.xcodeproj -scheme BenitoServer
  CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=`.
- `admin.json` next to a database holds the local admin API token. Never read the one in
  `~/Library/Application Support/Benito`.
- `apps/Benito/Sources/Generated/GitSHA.swift` is generated at build time; never commit it.
- Deployment guides: `docs/deploy-macos.md`, `docs/deploy-tailscale.md`, `docs/deploy-vps.md`.
