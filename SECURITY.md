# Security policy

Benito stores family and baby data on a server you run yourself. We take reports seriously.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting**: the repository's *Security* tab → *Report a vulnerability*. Please don't open a public issue. Include the version or commit, steps to reproduce, and the impact you expect. You should get an answer within a week.

## Supported versions

Only the latest `main` is supported. Fixes are not backported.

## How Benito protects data, and the known limits

- **Accounts.** New people join with a per-device P-256 key held in the Secure Enclave (Keychain on the Simulator). The server stores only public keys. Older email/password accounts use Argon2 password hashes.
- **Sessions.** Bearer tokens, valid 30 days and extended while in use. Removing someone from a family ends their sessions.
- **Invites.** Single use, expire after 72 hours, revocable, and stored only as a SHA-256 hash of the secret. Anyone who holds an unused invite link can join, so send it only to the person you mean.
- **Caregivers.** Can log events but can't invite or remove people. Optional end date.
- **Transport.** Use HTTPS (Tailscale Serve or a reverse proxy with TLS) for anything beyond your home network. A LAN listener (`BIND_ADDR=…,0.0.0.0:8081`) is **plain HTTP**: invites, the redeem secret and bearer tokens cross your Wi-Fi unencrypted. Only enable it on a network you trust. Certificate pinning for LAN endpoints is planned (see `docs/plans/oss-onboarding-sharing.md`).
- **Backups.** The whole database is one SQLite file. Back it up, and protect the backups like the data itself.
- **No third parties.** No analytics or crash reporting. Optional Live Activity pushes go through Apple Push Notification service with your own key.
