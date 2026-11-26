# Releasing the iPhone and iPad app

How the official build (`com.mikeroysoft.benito`, team `PVF5R8D8Q2`) gets to TestFlight and the App Store, and how the repository and website go public. Anyone else can ship their own build the same way with their own team and bundle prefix.

| Piece | Where |
|---|---|
| Archive and upload | `scripts/release-ios.sh` (GitHub Actions on `ios-v*` tags: `.github/workflows/release-ios.yml`) |
| Website and repository switches | `scripts/go-public.sh` (`check`, `site`, `repo`) |
| App Store text | `fastlane/metadata/` (plain text files in the layout `fastlane deliver` reads) |
| App Store screenshots | `fastlane/screenshots/en-US/` |
| Privacy manifest | `apps/Shared/PrivacyInfo.xcprivacy` (in the app and the widget extension) |

## First release

Do these in order. Steps 1 to 3 make the privacy and support pages reachable, which App Review needs.

1. **DNS.** Where `mikeroysoft.com` is hosted, add `benito  CNAME  mikeroysoft-org.github.io.`
2. **Website.** `scripts/go-public.sh site` turns on GitHub Pages, sets the repository variables the workflow reads (`PAGES_ENABLED`, `APPLE_TEAM_ID`, `BENITO_BUNDLE_ID`) and starts a deploy. `scripts/go-public.sh check` shows when the site and the universal-links file are live.
3. **Repository.** `scripts/go-public.sh repo` scans the history for secrets, makes the repository public and turns on private vulnerability reporting, Dependabot alerts and secret scanning. The App Store description and the review notes link to the repository, so do this before submitting.
4. **App record.** In [App Store Connect](https://appstoreconnect.apple.com/apps) choose Apps › + › New App: platform iOS, name from `fastlane/metadata/en-US/name.txt`, language English (U.S.), bundle ID `com.mikeroysoft.benito`, SKU `benito-ios`. Apple offers no API for this step.
5. **Local settings.** `apps/Benito/Config/Local.xcconfig` (gitignored) needs:

   ```
   DEVELOPMENT_TEAM = PVF5R8D8Q2
   BENITO_BUNDLE_PREFIX = com.mikeroysoft
   BENITO_ENTITLEMENTS = Resources/Benito-UniversalLinks.entitlements
   ```

6. **Build.** `scripts/release-ios.sh` archives the Release build and uploads it. It signs with the Apple ID in Xcode › Settings › Accounts, or with an App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`). The build shows up under TestFlight after processing.
7. **Listing.** Either paste the files from `fastlane/metadata/en-US/` and drag in the screenshots, or upload them all at once:

   ```bash
   brew install fastlane
   key="$(mktemp)"   # fastlane wants the key's content in JSON; build it for one run, outside the repo
   jq -n --rawfile key ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8 \
     '{key_id: "<KEYID>", issuer_id: "<ISSUER>", key: $key, in_house: false}' > "$key"
   fastlane deliver --api_key_path "$key"; rm -f "$key"
   ```

   The key is an App Store Connect API team key with the App Manager role (Users and Access › Integrations). This uploads text, review notes and screenshots; it does not submit.
8. **Answers App Store Connect asks for by hand:**

   | Page | Answer |
   |---|---|
   | Pricing and Availability | Free, all countries and regions |
   | App Privacy › Data collection | "No, we do not collect data from this app" (Data Not Collected). Policy URL: `https://benito.mikeroysoft.com/privacy/` |
   | Age rating | "None" or "No" to every question (4+). Not in the Kids category: the app is for parents |
   | Category | Health & Fitness, secondary Lifestyle |
   | Content rights | No third-party content |
   | Export compliance | Not asked: `ITSAppUsesNonExemptEncryption` is `false` in `project.yml` |
   | Sign-in required (App Review) | No. Paste `fastlane/metadata/review_information/notes.txt` into Notes, and add your own contact name, phone and email |
   | Digital Services Act (EU) | Declare trader or non-trader status; without it the app is not offered in the EU |

9. **Submit.** Pick the processed build on the version page and choose Add for Review.

## After approval

- Put the listing URL in `GET_BENITO_URL` in `site/assets/config.js`, and update the "Not on the App Store yet" lines: `grep -rn 'App Store yet' README.md site`.
- Update row 4 of the decisions table in `SPEC.md`.

## Later releases

The server must stay compatible with the App Store build people already have, so deploy server changes before an app release that needs them (see CONTRIBUTING.md).

1. Raise `MARKETING_VERSION` for all three targets in `apps/Benito/project.yml`, run `xcodegen generate` in `apps/Benito` (XcodeGen 2.46.0), write `fastlane/metadata/en-US/release_notes.txt`, and merge that pull request.
2. Push a tag named `ios-v` plus the version, from the merge commit on `main`. Only you can create, move, or delete these tags:

   ```bash
   git checkout main && git pull
   git tag ios-v1.0.1
   git push origin ios-v1.0.1
   ```

3. Approve the `release` environment when GitHub asks. The workflow archives a Release build (build number `YYYYMMDDHHMM` UTC) and uploads it to App Store Connect. It does **not** submit the app for review.
4. After processing (10 to 30 minutes), install the build from TestFlight on the test phone and check it.
5. In [App Store Connect](https://appstoreconnect.apple.com/apps), create the new version if needed, paste the release notes, pick the processed build, and submit for review. People on the App Store build get the update once Apple approves it.

To upload from your Mac instead of GitHub (a clean tree, Xcode signed in, or the API key in the environment): `scripts/release-ios.sh`. That also uploads only; you still submit in App Store Connect.

### GitHub secrets and variables

The workflow runs on a GitHub-hosted macOS runner, in the existing `release` environment (you are the reviewer). It signs with Xcode's automatic signing and the App Store Connect API key, and prefers Apple's cloud-managed certificates so the key is the only signing secret. Official team and bundle values come from repository variables already used by the Mac release workflow.

Add these secrets on the **release** environment (Settings › Environments › release). Do not commit them, and do not paste them into chat.

| Name | Kind | What to put there |
|---|---|---|
| `ASC_KEY_ID` | secret | Key ID of an App Store Connect API **team** key with the App Manager role (Users and Access › Integrations). The same key used for `fastlane deliver` is fine. |
| `ASC_ISSUER_ID` | secret | Issuer ID shown on that Integrations page (a UUID). |
| `ASC_KEY_P8` | secret | Base64 of the key file (`AuthKey_<KEYID>.p8`). Encode it on your Mac with `base64 -i AuthKey_<KEYID>.p8 \| pbcopy` and paste the single line. Keep the `.p8` outside the repo. |

The workflow already reads these repository variables (Settings › Variables); they are not secrets:

| Name | Typical official value |
|---|---|
| `APPLE_TEAM_ID` | `PVF5R8D8Q2` (already set) |
| `BENITO_BUNDLE_PREFIX` | `com.mikeroysoft` (optional if `BENITO_BUNDLE_ID` is set) |
| `BENITO_BUNDLE_ID` | `com.mikeroysoft.benito` (already set) |

If `BENITO_BUNDLE_PREFIX` is unset, the workflow uses `BENITO_BUNDLE_ID` with a trailing `.benito` removed. Setting the prefix variable is still a good idea: the Mac release workflow reads it too.

The workflow writes a throwaway `apps/Benito/Config/Local.xcconfig` from those variables (including `BENITO_ENTITLEMENTS = Resources/Benito-UniversalLinks.entitlements`) and sets `ASC_KEY_PATH` to a temp copy of the decoded `.p8`. `scripts/release-ios.sh` then archives and uploads.

If a run fails because Xcode cannot find an iOS Distribution certificate, export one from Keychain Access (or Apple Developer › Certificates) as a `.p12` and add these optional secrets to the same environment, then re-run:

| Name | Kind | What to put there |
|---|---|---|
| `IOS_DISTRIBUTION_P12` | secret | Base64 of the `.p12` (`base64 -i Certificates.p12 \| pbcopy`). |
| `IOS_DISTRIBUTION_P12_PASSWORD` | secret | The password you set when exporting the `.p12`. |

A Developer ID certificate (the Mac server one) will not work here. This must be an **iOS Distribution** (Apple Distribution) certificate for team `PVF5R8D8Q2`.

## Screenshots

App Store Connect needs one iPhone set (6.9-inch, 1320 × 2868) and one iPad set (13-inch, 2064 × 2752); it scales them for smaller devices. The app has launch hooks for this, so no tapping is needed. On a booted Simulator with the app in "This iPhone only" mode:

```bash
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4
SIMCTL_CHILD_BENITO_HIDE_TIPS=1 SIMCTL_CHILD_BENITO_PROTOTYPE_TAB=2 \
  xcrun simctl launch booted com.mikeroysoft.benito
xcrun simctl io booted screenshot fastlane/screenshots/en-US/03-timeline.png
```

`BENITO_PROTOTYPE_TAB` is `0` Home, `1` Log, `2` Timeline, `3` Account or `timer`; `BENITO_PROTOTYPE_SHEET` is `feed`, `diaper` or `sleep` on Home.

## What App Review looks at

- **No server needed to try it.** "This iPhone only" in onboarding runs every logging feature with no account. The review notes say so.
- **Account deletion (guideline 5.1.1(v)).** Account › Delete account… calls `DELETE /me` on the family's server; Account › Erase all data… clears an on-device install.
- **Local network prompt.** `NSLocalNetworkUsageDescription` and `NSBonjourServices` cover finding the server on Wi-Fi.
- **Apple Watch.** The store text only claims the Live Activity in the Smart Stack. The `BenitoWatch` target is a stub and is not embedded in the app.
