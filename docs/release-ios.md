# Releasing the iPhone and iPad app

How the official build (`com.mikeroysoft.benito`, team `PVF5R8D8Q2`) gets to TestFlight and the App Store, and how the repository and website go public. Anyone else can ship their own build the same way with their own team and bundle prefix.

| Piece | Where |
|---|---|
| Archive and upload | `scripts/release-ios.sh` |
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
   fastlane deliver --api_key_path ~/.appstoreconnect/benito-api-key.json
   ```

   The JSON file holds `key_id`, `issuer_id` and `key_filepath` for an App Store Connect API key with the App Manager role.
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

1. Raise `MARKETING_VERSION` for all three targets in `apps/Benito/project.yml`, run `xcodegen generate` in `apps/Benito`, and commit.
2. Write `fastlane/metadata/en-US/release_notes.txt`.
3. `scripts/release-ios.sh`, then submit the new version in App Store Connect.

The server must stay compatible with the App Store build people already have, so deploy server changes before an app release that needs them (see CONTRIBUTING.md).

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
