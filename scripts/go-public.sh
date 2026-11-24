#!/usr/bin/env bash
# One-time launch switches for the GitHub side. Needs the gh CLI signed in as a repo admin.
# Background and the App Store half: docs/release-ios.md.
#
#   scripts/go-public.sh site   publish /site to https://benito.mikeroysoft.com (GitHub Pages)
#   scripts/go-public.sh repo   make the repository public and turn on the security settings
#   scripts/go-public.sh check  show what is already done; changes nothing
#
# Both are safe to run again. `site` works while the repo is still private (paid GitHub plans).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="mikeroySoft-org/benito-app"
DOMAIN="$(tr -d '[:space:]' < "$ROOT/site/CNAME")"
PAGES_HOST="mikeroysoft-org.github.io"
LOCAL="$ROOT/apps/Benito/Config/Local.xcconfig"

setting() { [[ -f "$LOCAL" ]] && sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]/]+).*/\1/p" "$LOCAL" | tail -1; }
dns_target() { dig +short CNAME "$DOMAIN" 2>/dev/null | sed 's/\.$//' | tr '[:upper:]' '[:lower:]'; }
confirm() { read -r -p "$1 Type '$2' to continue: " answer; [[ "$answer" == "$2" ]] || { echo "Stopped."; exit 1; }; }

check() {
  local pages
  pages="$(gh api "repos/$REPO/pages" --jq '"\(.build_type), domain \(.cname // "none"), https \(.https_enforced)"' 2>/dev/null)" || pages="off"
  echo "Pages:                 $pages"
  echo "Repository visibility: $(gh api "repos/$REPO" --jq .visibility)"
  echo "PAGES_ENABLED:         $(gh variable get PAGES_ENABLED -R "$REPO" 2>/dev/null || echo "unset")"
  echo "APPLE_TEAM_ID:         $(gh variable get APPLE_TEAM_ID -R "$REPO" 2>/dev/null || echo "unset")"
  echo "BENITO_BUNDLE_ID:      $(gh variable get BENITO_BUNDLE_ID -R "$REPO" 2>/dev/null || echo "unset")"
  echo "DNS $DOMAIN: $(dns_target || true) (want $PAGES_HOST)"
  echo "Site:                  $(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$DOMAIN/privacy/" || true) for https://$DOMAIN/privacy/"
  echo "Universal links file:  $(curl -s -m 10 "https://$DOMAIN/.well-known/apple-app-site-association" | jq -r '.applinks.details[0].appIDs[0]' 2>/dev/null || echo "not served")"
}

site() {
  local team prefix
  team="$(setting DEVELOPMENT_TEAM)"; prefix="$(setting BENITO_BUNDLE_PREFIX)"
  [[ -n "$team" && -n "$prefix" ]] || { echo "Set DEVELOPMENT_TEAM and BENITO_BUNDLE_PREFIX in $LOCAL first." >&2; exit 1; }
  if [[ "$(dns_target)" != "$PAGES_HOST" ]]; then
    echo "DNS is not ready. Add this record where mikeroysoft.com is hosted, then run this again:" >&2
    echo "  ${DOMAIN%%.*}  CNAME  $PAGES_HOST." >&2
    exit 1
  fi
  confirm "Publish the website at https://$DOMAIN (universal links for $team.$prefix.benito)." "publish"

  gh api "repos/$REPO/pages" >/dev/null 2>&1 || gh api -X POST "repos/$REPO/pages" -f build_type=workflow >/dev/null
  gh api -X PUT "repos/$REPO/pages" -f cname="$DOMAIN" >/dev/null
  gh variable set APPLE_TEAM_ID -R "$REPO" --body "$team"
  gh variable set BENITO_BUNDLE_ID -R "$REPO" --body "$prefix.benito"
  gh variable set PAGES_ENABLED -R "$REPO" --body true
  gh workflow run pages.yml -R "$REPO" --ref main
  echo "Deploy started: gh run watch -R $REPO  (first HTTPS certificate can take up to an hour)."
  echo "When https://$DOMAIN loads, enforce HTTPS: gh api -X PUT repos/$REPO/pages -F https_enforced=true"
}

repo() {
  if command -v gitleaks >/dev/null; then
    (cd "$ROOT" && gitleaks git --no-banner --redact .) || { echo "gitleaks found something. Fix it before going public." >&2; exit 1; }
  else
    echo "gitleaks is not installed; skipping the secret scan of the history (brew install gitleaks)." >&2
  fi
  echo "Open pull requests and every branch on GitHub become public too:"
  gh pr list -R "$REPO" --json number,title --jq '.[] | "  #\(.number) \(.title)"'
  confirm "Make $REPO PUBLIC, with its full history. This can't be taken back once people clone it." "public"

  gh repo edit "$REPO" --visibility public --accept-visibility-change-consequences
  gh repo edit "$REPO" --homepage "https://$DOMAIN" --delete-branch-on-merge \
    --add-topic baby-tracker --add-topic self-hosted --add-topic swiftui --add-topic ios --add-topic rust --add-topic sqlite
  # SECURITY.md and the issue template send reporters to private vulnerability reporting.
  gh api -X PUT "repos/$REPO/private-vulnerability-reporting" >/dev/null
  gh api -X PUT "repos/$REPO/vulnerability-alerts" >/dev/null
  gh api -X PATCH "repos/$REPO" --input - >/dev/null <<'JSON'
{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}
JSON
  echo "Public: https://github.com/$REPO"
}

case "${1:-}" in
  site) site ;;
  repo) repo ;;
  check) check ;;
  *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
