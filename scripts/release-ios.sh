#!/usr/bin/env bash
# Archive the iPhone/iPad app and send it to App Store Connect (TestFlight / App Store review).
# Steps around it (app record, metadata, submitting): docs/release-ios.md.
#
#   scripts/release-ios.sh              archive, then upload to App Store Connect
#   scripts/release-ios.sh --no-upload  archive, then write a signed .ipa under build/release-ios/export
#   scripts/release-ios.sh --archive    archive only (checks that the Release device build signs)
#
# Signing is Xcode's automatic signing for the team in apps/Benito/Config/Local.xcconfig.
# It uses the Apple ID signed in to Xcode, or an App Store Connect API key when all three are set:
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (path to AuthKey_<id>.p8; keep it outside the repo)
# BUILD_NUMBER overrides the build number (default: UTC timestamp, always increasing).
set -euo pipefail

MODE=upload
case "${1:-}" in
  "") ;;
  --no-upload) MODE=export ;;
  --archive) MODE=archive ;;
  *) echo "usage: $0 [--no-upload | --archive]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/apps/Benito"
OUT="$ROOT/build/release-ios"
ARCHIVE="$OUT/Benito.xcarchive"
LOCAL="$APP/Config/Local.xcconfig"

setting() { sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*([^[:space:]/]+).*/\1/p" "$LOCAL" | tail -1; }

[[ -f "$LOCAL" ]] || { echo "Missing $LOCAL (copy Local.xcconfig.example and set your team)." >&2; exit 1; }
TEAM="$(setting DEVELOPMENT_TEAM)"
[[ -n "$TEAM" ]] || { echo "DEVELOPMENT_TEAM is empty in $LOCAL." >&2; exit 1; }
PREFIX="$(setting BENITO_BUNDLE_PREFIX)"
[[ -n "$PREFIX" && "$PREFIX" != "org.example" ]] || { echo "Set BENITO_BUNDLE_PREFIX in $LOCAL." >&2; exit 1; }

# The build embeds the commit; an archive of uncommitted code can't be traced back.
if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
  echo "Uncommitted changes in the working tree. Commit or stash them first." >&2
  exit 1
fi

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" || -n "${ASC_ISSUER_ID:-}" || -n "${ASC_KEY_PATH:-}" ]]; then
  [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -f "${ASC_KEY_PATH:-}" ]] \
    || { echo "Set all of ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (an existing .p8), or none." >&2; exit 1; }
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
SHA="$(git -C "$ROOT" rev-parse --short HEAD)"

mkdir -p "$OUT"
rm -rf "$ARCHIVE" "$OUT/export"
(cd "$APP" && xcodegen generate >/dev/null)
VERSION="$(sed -n -E 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"([^"]+)".*/\1/p' "$APP/project.yml" | head -1)"
echo "Benito $VERSION ($BUILD_NUMBER), commit $SHA, bundle $PREFIX.benito, team $TEAM"

xcodebuild archive \
  -project "$APP/Benito.xcodeproj" -scheme Benito -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" -derivedDataPath "$OUT/DerivedData" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  > "$OUT/archive.log" 2>&1 || { tail -n 40 "$OUT/archive.log" >&2; echo "Archive failed. Full log: $OUT/archive.log" >&2; exit 1; }
echo "Archived: $ARCHIVE"
[[ "$MODE" == archive ]] && exit 0

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$MODE</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>uploadSymbols</key><true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  > "$OUT/export.log" 2>&1 || { tail -n 40 "$OUT/export.log" >&2; echo "Export failed. Full log: $OUT/export.log" >&2; exit 1; }

if [[ "$MODE" == upload ]]; then
  echo "Uploaded $VERSION ($BUILD_NUMBER). It appears in App Store Connect › TestFlight after processing (10 to 30 minutes)."
else
  echo "Exported: $OUT/export"
fi
