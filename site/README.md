# benito.mikeroysoft.com

The Benito website: landing, privacy, support, and the web fallback for family invites.
Plain static files. GitHub Pages serves them with no build step (`.github/workflows/pages.yml`).

## Restyling

The pages are placeholders. Change anything in this table freely:

| File | Notes |
|---|---|
| `assets/site.css` | All styling. Keep a rule that shows `[data-when="<state>"]` only when `<body data-join-state="<state>">` matches (see the bottom of the file). |
| `index.html`, `privacy/index.html`, `support/index.html` | Copy and layout. Privacy must keep saying the app collects no data ("Data Not Collected"), unless the app actually changes. |
| `404.html` | Layout. Keep its small `/join` redirect script. |
| `assets/benito-icon.png`, new images and fonts | Add or replace as you like. Host fonts here (no third-party CDNs), because the privacy page promises no trackers. |

## Plumbing: keep intact

CI (`Check plumbing` and `Test join decoding`) fails if any of these break.

| File | Why it matters |
|---|---|
| `CNAME` | Must contain exactly `benito.mikeroysoft.com`. Pages uses it for the custom domain. |
| `.nojekyll` | Stops Jekyll, which would skip `.well-known/`. |
| `.well-known/apple-app-site-association` | Lets iOS open `https://benito.mikeroysoft.com/join…` links straight in the app (universal links). No file extension, JSON only. The committed `appIDs` value is a placeholder: the workflow fills in `APPLE_TEAM_ID.BENITO_BUNDLE_ID` from repo variables. Keep the `/join/*` and `/join` components. |
| `assets/join.js` | Reads the invite from the URL fragment (`#p=…`) in the browser and fills the join page. The part after `#` never reaches the web server, so the single-use secret stays out of logs. Don't add analytics or any script that reads `location.hash` or sends it anywhere. |
| `join/index.html` | Restyle freely, but keep these: `<script src="/assets/join.js" defer>`, `<body data-join-state="loading">`, the four `data-when` sections (`loading`, `ready`, `expired`, `invalid`), the links `data-join-open`, `data-join-get` (put the App Store URL in its `data-store-url`) and the button `data-join-copy`, the text slots `data-join-family`, `data-join-inviter`, `data-join-role`, `data-join-expires` and `data-join-copy-status`, and `<meta name="referrer" content="no-referrer">` and `noindex`. `data-join-expires` gets a phrase that reads after the word "expires" ("in 3 days", "tomorrow", "on Dec 31, 2029"), with the exact time as its tooltip. |
| `tests/join.test.mjs` | Checks that the page decodes exactly what the app's `FamilyInviteLink` encodes. Not published. |

## How an invite link works

1. The app shares `https://benito.mikeroysoft.com/join#p=<base64url JSON>`.
2. If Benito is installed and the AASA file is live, iOS opens the app directly, and this site never loads.
3. If not, `/join/` loads. `join.js` decodes the fragment and shows "Mike invited you to Roy family". It offers **Open in Benito** (`benito://join?p=…`), **Get Benito**, and **Copy invite**. The app's paste box accepts the copied link.

## Deploying

- Preview locally: `cd site && python3 -m http.server 8000`, then open <http://localhost:8000/join/#p=…>.
- Deploys need Pages enabled with Source set to "GitHub Actions", and the repo variable `PAGES_ENABLED=true`. Until then, the workflow only builds and checks.
- DNS needs `benito.mikeroysoft.com CNAME mikeroysoft-org.github.io.`
- Pages on a private repo needs a paid GitHub plan.
- Universal links need the real Team ID. Set the repo variables `APPLE_TEAM_ID` and `BENITO_BUNDLE_ID`.
- The app side is opt-in: builds signed by that team set `BENITO_ENTITLEMENTS = Resources/Benito-UniversalLinks.entitlements` in `apps/Benito/Config/Local.xcconfig`. Other builds still open invites: this page hands off to `benito://join?p=…`.
