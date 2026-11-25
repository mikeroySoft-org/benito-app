# Releasing Benito Server for Mac

Benito Server (`apps/BenitoServer`) ships as a Developer ID signed, notarized DMG on GitHub Releases. Installed copies update themselves with Sparkle 2 from `https://benito.mikeroysoft.com/appcast.xml`. One script, `scripts/release-mac.sh`, builds everything; publishing is two manual steps.

The source stays MIT. A copy built from source has no update key, never checks the feed, and updates with `git pull` and a rebuild.

## One-time setup

Do this once on the Mac that cuts releases.

1. **Tools.** Xcode 16 or later, `brew install xcodegen`, and Rust from <https://rustup.rs> with both Mac targets:

   ```bash
   rustup target add aarch64-apple-darwin x86_64-apple-darwin
   ```

2. **Developer ID Application certificate.** In Xcode: Settings, Accounts, your team, Manage Certificates, +, Developer ID Application (only the account holder can create one). Check it is there and copy the full name:

   ```bash
   security find-identity -v -p codesigning
   #  1) ABCDEF... "Developer ID Application: Your Name (TEAMID1234)"
   ```

3. **Notary credentials.** Create an app-specific password at <https://account.apple.com> (Sign-In and Security), then store it in the keychain under a profile name. The password itself never goes into a file or the environment:

   ```bash
   xcrun notarytool store-credentials benito-notary \
     --apple-id you@example.com --team-id TEAMID1234
   ```

4. **Sparkle update key.** Sparkle's tools come with the pinned release that `apps/BenitoServer/Scripts/fetch-sparkle.sh` downloads (any build of the app runs it), then:

   ```bash
   apps/BenitoServer/Vendor/Sparkle/bin/generate_keys
   ```

   It creates an EdDSA key pair, keeps the private key in your login keychain ("Private key for signing Sparkle updates"), and prints the public key. Run it again with `-p` to print the public key later.

   - The public key goes into every release as `BENITO_SPARKLE_PUBLIC_KEY` (below). The script hands it to Xcode, which writes it to `SUPublicEDKey` in the app's Info.plist. It is not committed, so source builds stay without a key.
   - Back up the private key somewhere safe and offline (`generate_keys -x benito-sparkle.key`, then delete the file from disk). If it is lost, installed copies can never be updated again and everyone has to download a new DMG by hand.

5. **Bundle id.** The app's bundle id is `<BENITO_BUNDLE_PREFIX>.benito.serverapp` (not `.benito.server`: with the prefix `com.mikeroysoft` that would be the server's launchd label). Set the prefix in `apps/Benito/Config/Local.xcconfig` (or export `BENITO_BUNDLE_PREFIX`), and never change it after the first release: Sparkle refuses an update with a different bundle id. The script refuses to sign the default `org.example` prefix.

6. **Environment.** Put these where your shell finds them (for example a private `~/.benito-release.env` you `source`; never in the repo):

   ```bash
   export BENITO_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID1234)"
   export BENITO_TEAM_ID="TEAMID1234"
   export BENITO_NOTARY_PROFILE="benito-notary"
   export BENITO_SPARKLE_PUBLIC_KEY="<what generate_keys printed>"
   ```

## Cutting a release

1. Set the versions and commit:
   - `MARKETING_VERSION` in `apps/BenitoServer/project.yml`: the version people see (`0.2.0`).
   - `CURRENT_PROJECT_VERSION` in the same file: a whole number that goes up by at least one every release. Sparkle compares this number, not the visible version.
   - `version` in `server/Cargo.toml`: always the same value as `MARKETING_VERSION`, so the app and the server it installs show one version. The script refuses to build when they differ. Run `cargo build` in `server/` afterwards so `Cargo.lock` follows.
2. Run the script from a clean tree:

   ```bash
   scripts/release-mac.sh
   ```

   It stops early, before building, if a variable, the certificate, the notary profile or a Rust target is missing, if the tree has uncommitted changes, or if the build number is not higher than the one in `site/appcast.xml`.

What it does, in order:

| Step | Detail |
|---|---|
| Server | `cargo build --release --locked` for `aarch64-apple-darwin` and `x86_64-apple-darwin`, joined with `lipo` |
| App | `xcodegen generate`, then `xcodebuild archive` (Release, universal) with the server passed as `BENITO_SERVER_BINARY`, which the project's build phase copies to `Contents/MacOS/benito-server` |
| Signing | Sparkle's helpers, the frameworks, the embedded server and then the app, inside out, with the hardened runtime and a secure timestamp |
| Checks | Version and build number, architectures of both executables, the embedded server answers `--version` with the version in `Cargo.toml`, `codesign --verify --deep --strict`, hardened runtime and team on each executable, `SUPublicEDKey` matches |
| DMG | `Benito-Server-<version>.dmg` with the app and an Applications shortcut; signed, notarized (`notarytool submit --wait`), stapled, checked with `spctl` |
| Appcast | Sparkle's `generate_appcast` signs the stapled DMG with the private key from the keychain and writes `appcast.xml`; the script then verifies that signature against `BENITO_SPARKLE_PUBLIC_KEY` |

Output lands in `build/release-mac/dist/` (gitignored): the DMG and `appcast.xml`. The script ends with their sizes and SHA-256 sums.

Options:

| Option | Use |
|---|---|
| `--unsigned` | Local dry run: ad-hoc signing, no hardened runtime, no notarization, no appcast. Needs none of the setup above. Add `--arch arm64` on a Mac without the Intel Rust target |
| `--version X.Y.Z`, `--build N` | Override the values in `project.yml` for this build |
| `--skip-notarize` | Sign with Developer ID but do not notarize. For testing the signing steps; the result must not be published |

Optional variables: `BENITO_BUNDLE_PREFIX`, `BENITO_DOWNLOAD_URL_PREFIX` (when the DMG is not hosted on this repo's GitHub Releases), and for CI `BENITO_SPARKLE_KEY_FILE` and `BENITO_NOTARY_KEYCHAIN`.

The script only writes inside the repository. It does not install anything and does not touch a Benito server running on the same Mac.

## Publishing

The appcast points at `https://github.com/<owner>/<repo>/releases/download/mac-v<version>/Benito-Server-<version>.dmg`, so the tag name and the file name are fixed. The repository has to be public for that link to work without signing in.

1. Tag and push: `git tag mac-v0.2.0 && git push origin mac-v0.2.0`.
2. Create the GitHub Release for the tag, attach the DMG, and publish it (a draft's download link does not work):

   ```bash
   gh release create mac-v0.2.0 build/release-mac/dist/Benito-Server-0.2.0.dmg \
     --title "Benito Server 0.2.0" --notes "What changed, in a few lines."
   ```

3. Check the link: `curl -sIL <the URL above> | grep -i '^HTTP'` ends with `200`.
4. Publish the feed. Only now do installed copies see the release:

   ```bash
   cp build/release-mac/dist/appcast.xml site/appcast.xml
   git add site/appcast.xml && git commit -m "Benito Server 0.2.0 appcast" && git push
   ```

   The Pages workflow (`.github/workflows/pages.yml`) copies everything in `site/` except `README.md` and `tests/`, so the file is served at `https://benito.mikeroysoft.com/appcast.xml` with no other change. `scripts/check-site-plumbing.sh`, the workflow's "Check plumbing" step and `site/tests/join.test.mjs` look only at the join page, `CNAME`, `.nojekyll` and the app-site-association file; adding `appcast.xml` needs nothing from them, and `site/appcast.xml` is not a protected path. The feed is live only while Pages deploys (repository variable `PAGES_ENABLED=true`).

The feed lists the newest release only. Older DMGs stay downloadable from their GitHub Releases.

## How an update reaches a family

1. The app asks the feed once a day (`SUEnableAutomaticChecks`), or when someone chooses Check for Updates in the Overview pane. Automatic checks can be turned off there.
2. Sparkle shows the new version. On Install it downloads the DMG and checks the EdDSA signature against the key inside the running app and the Developer ID signature against the running app's.
3. Before the app relaunches, it asks the server for a snapshot (the same as Back Up Now) and waits up to 60 seconds for it. This is skipped when the server is not running or has no backup folder.
4. Sparkle swaps the app and relaunches it. The server keeps running throughout: it is a separate launchd job running its own copy of the binary, so phones keep syncing.

### The server itself

Updating the app does not change the running server. The service runs `~/Library/Application Support/Benito/bin/benito-server`, a copy made at install time, and the new app only carries a newer one inside its bundle. After an app update the app compares the bundled server with the installed one and, when they differ, offers **Update Server**. That takes a snapshot first, replaces the installed binary, and restarts the service (a few seconds of downtime). Until someone chooses it, the old server keeps serving.

`scripts/macos-service.sh install` manages the same service (same label, plist, paths and `benito.env`), so a Mac can move from the script to the app with Update Server. Going the other way is not symmetrical: running the script on a Mac the app looks after replaces the server with a source build and brings back the nightly `com.mikeroysoft.benito.backup` job, which then writes to the same folder as the server's own backups. The app notices the changed program and offers Update Server again, which removes that job.

## Rolling back

Sparkle never installs an older version, so rolling back is by hand.

1. **Stop the rollout.** Put the previous `appcast.xml` back (`git revert` the feed commit and push). Macs that have not updated yet stay where they are.
2. **App.** Download the older DMG from its GitHub Release and drag the app over the one in Applications. Use Update Server in the app (it offers whenever the bundled and installed servers differ) to put the older server back.
3. **Data, only if the newer server changed it in a way the older one cannot read.** A newer server may have migrated the database. Restore the snapshot taken just before the update: stop the server in the app, restore from the Backups pane, start it again. The same from a terminal, with the server stopped:

   ```bash
   cd "$HOME/Library/Application Support/Benito"
   BENITO_ENV_FILE="$PWD/benito.env" bin/benito-server restore "$HOME/Backups/benito/benito-YYYYmmdd-HHMMSS.db"
   ```

   `restore` refuses while a server is running, checks the snapshot, and keeps the replaced database as `pre-restore-YYYYmmdd-HHMMSS.db` in the backup folder. Anything logged after that snapshot is in the pre-restore file, not in the restored database.

A bad release that is already installed widely is better fixed forward: cut a new release with a higher build number.

## Protected files a person has to add

`.github/workflows/**` and `.factory.toml` are protected paths. These are ready to paste.

### `.github/workflows/release-mac.yml`

Runs when a `mac-v*` tag is pushed, builds with the script, and creates a draft release with the DMG and the appcast attached. Publishing the draft and copying `appcast.xml` to `site/` stay manual (steps 2 to 4 above).

Repository secrets:

| Secret | Value |
|---|---|
| `MAC_DEVELOPER_ID_P12` | The Developer ID Application certificate and private key exported from Keychain Access as `.p12`, then `base64 -i cert.p12` |
| `MAC_DEVELOPER_ID_P12_PASSWORD` | The password chosen at export |
| `NOTARY_API_KEY_P8` | An App Store Connect API key (Users and Access, Integrations, team key with the Developer role), `base64 -i AuthKey_XXXX.p8` |
| `NOTARY_API_KEY_ID`, `NOTARY_API_ISSUER_ID` | That key's id and the issuer id shown above the key list |
| `SPARKLE_PRIVATE_KEY` | The contents of the file written by `generate_keys -x` |

Repository variables: `BENITO_DEVELOPER_ID` (the full identity name), `APPLE_TEAM_ID` (already used by `pages.yml`), `BENITO_SPARKLE_PUBLIC_KEY`, `BENITO_BUNDLE_PREFIX`.

```yaml
name: release-mac

on:
  push:
    tags: ["mac-v*"]

permissions:
  contents: write

concurrency:
  group: release-mac
  cancel-in-progress: false

jobs:
  release:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -s "$(ls -d /Applications/Xcode_16*.app | sort -V | tail -1)"

      - name: Install tools
        run: |
          brew install xcodegen
          rustup target add aarch64-apple-darwin x86_64-apple-darwin

      - name: Import signing and notary credentials
        env:
          P12_BASE64: ${{ secrets.MAC_DEVELOPER_ID_P12 }}
          P12_PASSWORD: ${{ secrets.MAC_DEVELOPER_ID_P12_PASSWORD }}
          NOTARY_KEY_BASE64: ${{ secrets.NOTARY_API_KEY_P8 }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_API_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_API_ISSUER_ID }}
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          umask 077
          keychain="$RUNNER_TEMP/release.keychain-db"
          keychain_password="$(openssl rand -hex 24)"
          security create-keychain -p "$keychain_password" "$keychain"
          security set-keychain-settings -lut 21600 "$keychain"
          security unlock-keychain -p "$keychain_password" "$keychain"

          echo "$P12_BASE64" | base64 --decode > "$RUNNER_TEMP/developer-id.p12"
          security import "$RUNNER_TEMP/developer-id.p12" -P "$P12_PASSWORD" \
            -f pkcs12 -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
          security set-key-partition-list -S apple-tool:,apple: -s -k "$keychain_password" "$keychain" > /dev/null
          security list-keychains -d user -s "$keychain"
          rm -f "$RUNNER_TEMP/developer-id.p12"

          echo "$NOTARY_KEY_BASE64" | base64 --decode > "$RUNNER_TEMP/notary.p8"
          xcrun notarytool store-credentials benito-notary \
            --key "$RUNNER_TEMP/notary.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
            --keychain "$keychain"
          rm -f "$RUNNER_TEMP/notary.p8"

          printf '%s' "$SPARKLE_PRIVATE_KEY" > "$RUNNER_TEMP/sparkle.key"

      - name: Build, sign and notarize
        env:
          BENITO_DEVELOPER_ID: ${{ vars.BENITO_DEVELOPER_ID }}
          BENITO_TEAM_ID: ${{ vars.APPLE_TEAM_ID }}
          BENITO_SPARKLE_PUBLIC_KEY: ${{ vars.BENITO_SPARKLE_PUBLIC_KEY }}
          BENITO_BUNDLE_PREFIX: ${{ vars.BENITO_BUNDLE_PREFIX }}
          BENITO_NOTARY_PROFILE: benito-notary
        run: |
          set -euo pipefail
          export BENITO_NOTARY_KEYCHAIN="$RUNNER_TEMP/release.keychain-db"
          export BENITO_SPARKLE_KEY_FILE="$RUNNER_TEMP/sparkle.key"
          scripts/release-mac.sh --version "${GITHUB_REF_NAME#mac-v}"

      - name: Create draft release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          version="${GITHUB_REF_NAME#mac-v}"
          gh release create "$GITHUB_REF_NAME" \
            "build/release-mac/dist/Benito-Server-$version.dmg" \
            build/release-mac/dist/appcast.xml \
            --draft --title "Benito Server $version" --generate-notes

      - name: Remove credentials
        if: always()
        run: |
          security delete-keychain "$RUNNER_TEMP/release.keychain-db" || true
          rm -f "$RUNNER_TEMP/sparkle.key" "$RUNNER_TEMP/notary.p8" "$RUNNER_TEMP/developer-id.p12"
```

The tag sets the visible version; the build number still comes from `CURRENT_PROJECT_VERSION` in `project.yml`, so raise it in the commit you tag. After the run, download `appcast.xml` from the draft, publish the draft, and commit the file as `site/appcast.xml`.

### `.factory.toml`

A gate check that builds the Mac app without signing. The project's build phase compiles the server with cargo and embeds it, so this also proves the bundle assembles. The first build on a machine downloads the pinned Sparkle release (`apps/BenitoServer/Scripts/fetch-sparkle.sh`), so a gate that runs offline needs `apps/BenitoServer/Vendor/` populated beforehand.

```toml
[[gate.check]]
name = "mac-server-app-build"
run = ["scripts/gate-env.sh", "apps/BenitoServer", "sh", "-c", "xcodegen generate && xcodebuild build -project BenitoServer.xcodeproj -scheme BenitoServer -derivedDataPath \"$TMPDIR/benito-dd-server-app\" CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM="]
```

Consider adding `"scripts/release-mac.sh"` to `protected_paths` in the same file: it is the script that holds the signing identity.
