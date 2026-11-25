#!/usr/bin/env bash
# Build a release of Benito Server.app (apps/BenitoServer) into build/release-mac/.
# See docs/release-mac.md.
#
#   scripts/release-mac.sh [--unsigned] [--version X.Y.Z] [--build N] [--arch universal|arm64]
#                          [--skip-notarize]
#
# Signed (default): universal benito-server, Developer ID signed app with the hardened runtime,
# notarized and stapled DMG, EdDSA-signed Sparkle appcast.
# --unsigned: the same steps with ad-hoc signing, no notarization and no appcast, for a local
# dry run on a Mac without the certificate.
#
# Environment for a signed release:
#   BENITO_DEVELOPER_ID          "Developer ID Application: Name (TEAMID)"
#   BENITO_TEAM_ID               the ten-character team id
#   BENITO_NOTARY_PROFILE        notarytool keychain profile (not needed with --skip-notarize)
#   BENITO_SPARKLE_PUBLIC_KEY    the base64 public key printed by Sparkle's generate_keys
# Optional:
#   BENITO_BUNDLE_PREFIX         bundle id prefix when apps/Benito/Config/Local.xcconfig has none
#   BENITO_NOTARY_KEYCHAIN       keychain file holding the notary profile (CI)
#   BENITO_SPARKLE_KEY_FILE      file with the Sparkle private key instead of the login keychain (CI)
#   BENITO_DOWNLOAD_URL_PREFIX   where the DMG will be downloaded from; defaults to this repo's
#                                GitHub Release for the tag mac-v<version>
#
# Writes only inside the repository (build/release-mac/, server/target/, the generated Xcode
# project), apart from the caches cargo, Xcode and Sparkle's generate_appcast keep for
# themselves. It never installs, starts or stops anything.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

SERVER_DIR="$ROOT/server"
CARGO_TARGET="$SERVER_DIR/target"
APP_DIR="$ROOT/apps/BenitoServer"
PROJECT_YML="$APP_DIR/project.yml"
PROJECT="$APP_DIR/BenitoServer.xcodeproj"
SCHEME="BenitoServer"
APP_NAME="Benito Server"
SITE_APPCAST="$ROOT/site/appcast.xml"
SITE_URL="https://benito.mikeroysoft.com/"
TAG_PREFIX="mac-v"

OUT="$ROOT/build/release-mac"
DERIVED="$OUT/DerivedData"
ARCHIVE="$OUT/BenitoServer.xcarchive"
STAGE="$OUT/stage"
SERVER_STAGE="$OUT/server"
DIST="$OUT/dist"
SERVER_BIN="$SERVER_STAGE/benito-server"
APP="$STAGE/app/$APP_NAME.app"
EMBEDDED_SERVER="$APP/Contents/MacOS/benito-server"
SPARKLE_BIN="$ROOT/apps/BenitoServer/Vendor/Sparkle/bin"

unsigned=0
skip_notarize=0
arch="universal"
version=""
build=""

die() {
  echo "error: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

need() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' not found on PATH"
  done
}

usage() {
  cat >&2 <<EOF
usage: $(basename "$0") [options]

  --unsigned              local dry run: ad-hoc signing, no notarization, no appcast
  --version X.Y.Z         app version (default: MARKETING_VERSION in project.yml)
  --build N               build number (default: CURRENT_PROJECT_VERSION in project.yml)
  --arch universal|arm64  default universal; arm64 only with --unsigned
  --skip-notarize         sign but do not notarize (the DMG is not fit to publish)

A signed release needs BENITO_DEVELOPER_ID, BENITO_TEAM_ID, BENITO_NOTARY_PROFILE and
BENITO_SPARKLE_PUBLIC_KEY. See docs/release-mac.md.
EOF
}

# First value of a "KEY: value" line in project.yml, quotes removed.
yml_setting() {
  sed -nE "/^[[:space:]]*$1:/{
s/^[[:space:]]*$1:[[:space:]]*\"?([^\"[:space:]]+)\"?.*$/\1/p
q
}" "$PROJECT_YML"
}

cargo_version() {
  sed -nE '/^version[[:space:]]*=/{
s/^version[[:space:]]*=[[:space:]]*"([^"]+)".*$/\1/p
q
}' "$SERVER_DIR/Cargo.toml"
}

# owner/repo of the origin remote when it is on GitHub, else empty.
github_slug() {
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  url="${url%.git}"
  case "$url" in
    git@github.com:*) echo "${url#git@github.com:}" ;;
    https://github.com/*) echo "${url#https://github.com/}" ;;
    *) echo "" ;;
  esac
}

# Architectures in a Mach-O file, sorted, space separated.
archs_of() {
  lipo -archs "$1" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ' | sed 's/ $//'
}

file_size() {
  du -h "$1" | cut -f1
}

file_sha256() {
  shasum -a 256 "$1" | cut -d' ' -f1
}

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
}

sign() {
  local path=$1
  shift
  if ((unsigned)); then
    # No hardened runtime: an ad-hoc signature has no team, so library validation would refuse
    # to load the embedded Sparkle framework.
    codesign --force --sign - "$@" "$path"
  else
    codesign --force --sign "$BENITO_DEVELOPER_ID" --options runtime --timestamp "$@" "$path"
  fi
}

has_hardened_runtime() {
  local info
  info="$(codesign -d --verbose=4 "$1" 2>&1)"
  [[ "$info" =~ flags=0x[0-9a-f]+\([a-z,-]*runtime ]]
}

signed_by_team() {
  local info
  info="$(codesign -d --verbose=2 "$1" 2>&1)"
  [[ "$info" == *"TeamIdentifier=$BENITO_TEAM_ID"* ]]
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --unsigned) unsigned=1 ;;
      --skip-notarize) skip_notarize=1 ;;
      --version)
        (($# >= 2)) || die "--version needs a value"
        version=$2
        shift
        ;;
      --build)
        (($# >= 2)) || die "--build needs a value"
        build=$2
        shift
        ;;
      --arch)
        (($# >= 2)) || die "--arch needs a value"
        arch=$2
        shift
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage
        die "unknown option: $1"
        ;;
    esac
    shift
  done

  case "$arch" in
    universal) rust_targets=(aarch64-apple-darwin x86_64-apple-darwin) expected_archs="arm64 x86_64" ;;
    arm64) rust_targets=(aarch64-apple-darwin) expected_archs="arm64" ;;
    *) die "--arch must be universal or arm64" ;;
  esac
  if ((!unsigned)) && [[ "$arch" != "universal" ]]; then
    die "a signed release is always universal; --arch arm64 needs --unsigned"
  fi

  [[ -n "$version" ]] || version="$(yml_setting MARKETING_VERSION)"
  [[ -n "$build" ]] || build="$(yml_setting CURRENT_PROJECT_VERSION)"
  [[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "version must look like 1.2.3, got '$version'"
  # Sparkle orders releases by CFBundleVersion, so it has to be a plain counter.
  [[ "$build" =~ ^[0-9]+$ ]] || die "build must be a whole number, got '$build'"

  server_version="$(cargo_version)"
  [[ -n "$server_version" ]] || die "could not read the server version from $SERVER_DIR/Cargo.toml"
  # The app and the server it carries share one version, so the Overview pane shows one number.
  [[ "$server_version" == "$version" ]] \
    || die "server version $server_version (server/Cargo.toml) differs from app version $version; set both to the same value"

  DMG="$DIST/Benito-Server-$version.dmg"
  APPCAST="$DIST/appcast.xml"
}

check_tools() {
  local installed host target
  need cargo xcodegen xcodebuild xcrun lipo hdiutil codesign ditto shasum git
  if command -v rustup >/dev/null 2>&1; then
    installed="$(rustup target list --installed)"
    for target in "${rust_targets[@]}"; do
      if ! grep -qx "$target" <<<"$installed"; then
        if [[ "$arch" == "universal" ]] && ((unsigned)); then
          die "Rust target $target is not installed. Run: rustup target add $target (or pass --arch arm64 for a local dry run)"
        fi
        die "Rust target $target is not installed. Run: rustup target add $target"
      fi
    done
  else
    # Without rustup there is exactly one target: the toolchain's own.
    host="$(rustc -vV | sed -n 's/^host: //p')"
    for target in "${rust_targets[@]}"; do
      [[ "$target" == "$host" ]] || die "building for $target needs rustup (https://rustup.rs), then: rustup target add $target"
    done
  fi
}

check_signing_prerequisites() {
  local name identities missing=() highest slug
  for name in BENITO_DEVELOPER_ID BENITO_TEAM_ID BENITO_SPARKLE_PUBLIC_KEY; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  if ((!skip_notarize)) && [[ -z "${BENITO_NOTARY_PROFILE:-}" ]]; then
    missing+=("BENITO_NOTARY_PROFILE")
  fi
  if ((${#missing[@]} > 0)); then
    die "a signed release needs ${missing[*]} in the environment (see docs/release-mac.md), or pass --unsigned for a local dry run"
  fi

  need security spctl
  [[ "$BENITO_DEVELOPER_ID" == "Developer ID Application: "* ]] ||
    die "BENITO_DEVELOPER_ID must be a 'Developer ID Application: ...' identity, got '$BENITO_DEVELOPER_ID'"
  [[ "$BENITO_DEVELOPER_ID" == *"($BENITO_TEAM_ID)" ]] ||
    die "BENITO_DEVELOPER_ID does not end with ($BENITO_TEAM_ID); check BENITO_TEAM_ID"
  identities="$(security find-identity -v -p codesigning)"
  [[ "$identities" == *"\"$BENITO_DEVELOPER_ID\""* ]] ||
    die "no valid code signing identity named '$BENITO_DEVELOPER_ID' in the keychain. Valid identities: $(echo; echo "$identities")"

  if [[ -n "${BENITO_SPARKLE_KEY_FILE:-}" && ! -f "$BENITO_SPARKLE_KEY_FILE" ]]; then
    die "BENITO_SPARKLE_KEY_FILE is not a file: $BENITO_SPARKLE_KEY_FILE"
  fi
  if [[ -n "${BENITO_NOTARY_KEYCHAIN:-}" && ! -f "$BENITO_NOTARY_KEYCHAIN" ]]; then
    die "BENITO_NOTARY_KEYCHAIN is not a file: $BENITO_NOTARY_KEYCHAIN"
  fi

  if ((!skip_notarize)); then
    step "checking the notary profile '$BENITO_NOTARY_PROFILE'"
    xcrun notarytool history --keychain-profile "$BENITO_NOTARY_PROFILE" \
      ${notary_keychain[@]+"${notary_keychain[@]}"} >/dev/null ||
      die "notarytool cannot use the profile '$BENITO_NOTARY_PROFILE'. Create it with: xcrun notarytool store-credentials $BENITO_NOTARY_PROFILE"
  fi

  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    die "the git tree has uncommitted changes; a signed release is built from a commit"
  fi

  download_prefix="${BENITO_DOWNLOAD_URL_PREFIX:-}"
  release_page=""
  if [[ -z "$download_prefix" ]]; then
    slug="$(github_slug)"
    [[ -n "$slug" ]] || die "origin is not a GitHub remote; set BENITO_DOWNLOAD_URL_PREFIX to the folder the DMG will be downloaded from"
    download_prefix="https://github.com/$slug/releases/download/$TAG_PREFIX$version/"
    release_page="https://github.com/$slug/releases/tag/$TAG_PREFIX$version"
  fi
  [[ "$download_prefix" == https://*/ ]] || die "the download URL prefix must be https and end with '/': $download_prefix"

  # Sparkle only offers a release whose build number is higher than the installed one.
  if [[ -f "$SITE_APPCAST" ]]; then
    highest="$(grep -oE 'sparkle:version[>=]"?[0-9]+' "$SITE_APPCAST" | grep -oE '[0-9]+$' | sort -n | tail -n 1 || true)"
    if [[ -n "$highest" ]] && ((build <= highest)); then
      die "build $build is not higher than build $highest already in site/appcast.xml; raise CURRENT_PROJECT_VERSION or pass --build"
    fi
  fi
}

clean_staging() {
  mkdir -p "$OUT"
  rm -rf "$STAGE" "$SERVER_STAGE" "$DIST" "$ARCHIVE"
  mkdir -p "$STAGE/app" "$SERVER_STAGE" "$DIST"
}

build_server() {
  local target built=()
  for target in "${rust_targets[@]}"; do
    step "building benito-server $server_version for $target"
    (cd "$SERVER_DIR" && cargo build --release --locked --target "$target" --target-dir "$CARGO_TARGET")
    [[ -x "$CARGO_TARGET/$target/release/benito-server" ]] || die "build output missing: $CARGO_TARGET/$target/release/benito-server"
    built+=("$CARGO_TARGET/$target/release/benito-server")
  done
  if ((${#built[@]} > 1)); then
    lipo -create "${built[@]}" -output "$SERVER_BIN"
  else
    cp "${built[0]}" "$SERVER_BIN"
  fi
  chmod 755 "$SERVER_BIN"
  [[ "$(archs_of "$SERVER_BIN")" == "$expected_archs" ]] ||
    die "$SERVER_BIN has architectures '$(archs_of "$SERVER_BIN")', expected '$expected_archs'"
}

archive_app() {
  local args
  step "generating the Xcode project"
  (cd "$APP_DIR" && xcodegen generate --quiet)

  args=(
    clean archive -quiet
    -project "$PROJECT" -scheme "$SCHEME" -configuration Release
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED"
    "ARCHS=$expected_archs" ONLY_ACTIVE_ARCH=NO
    "MARKETING_VERSION=$version" "CURRENT_PROJECT_VERSION=$build"
    "BENITO_SERVER_BINARY=$SERVER_BIN"
    CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER=
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
  )
  if [[ -n "${BENITO_BUNDLE_PREFIX:-}" ]]; then
    args+=("BENITO_BUNDLE_PREFIX=$BENITO_BUNDLE_PREFIX")
  fi
  if ((unsigned)); then
    args+=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO)
  else
    args+=(
      "CODE_SIGN_IDENTITY=$BENITO_DEVELOPER_ID" "DEVELOPMENT_TEAM=$BENITO_TEAM_ID"
      OTHER_CODE_SIGN_FLAGS=--timestamp ENABLE_HARDENED_RUNTIME=YES
      "BENITO_SPARKLE_PUBLIC_KEY=$BENITO_SPARKLE_PUBLIC_KEY"
    )
  fi

  step "archiving $APP_NAME $version ($build)"
  xcodebuild "${args[@]}"

  [[ -d "$ARCHIVE/Products/Applications/$APP_NAME.app" ]] || die "the archive has no $APP_NAME.app: $ARCHIVE"
  ditto "$ARCHIVE/Products/Applications/$APP_NAME.app" "$APP"
}

# Signs inside out. Sparkle ships ad-hoc signed, and Xcode signs only the outside of an embedded
# framework, so its helpers would fail notarization; an exported archive gets the same treatment
# from Xcode. Re-signing the app last reseals everything that changed beneath it.
sign_app() {
  local frameworks="$APP/Contents/Frameworks" sparkle item
  sparkle="$frameworks/Sparkle.framework"
  step "signing nested code"
  if [[ -d "$sparkle" ]]; then
    for item in XPCServices/Installer.xpc Autoupdate Updater.app; do
      if [[ -e "$sparkle/Versions/Current/$item" ]]; then
        sign "$sparkle/Versions/Current/$item"
      fi
    done
    if [[ -e "$sparkle/Versions/Current/XPCServices/Downloader.xpc" ]]; then
      # The downloader is sandboxed; its entitlements have to survive.
      sign "$sparkle/Versions/Current/XPCServices/Downloader.xpc" --preserve-metadata=entitlements
    fi
  fi
  if [[ -d "$frameworks" ]]; then
    for item in "$frameworks"/*; do
      [[ -e "$item" ]] || continue
      sign "$item"
    done
  fi
  sign "$EMBEDDED_SERVER"
  sign "$APP" --preserve-metadata=entitlements
}

verify_app() {
  local plist="$APP/Contents/Info.plist" main="$APP/Contents/MacOS/$APP_NAME"
  local reported bundle_id host entitlements item
  step "verifying the app"
  [[ -x "$main" ]] || die "missing app executable: $main"
  [[ -x "$EMBEDDED_SERVER" ]] || die "the app has no embedded server: $EMBEDDED_SERVER"

  [[ "$(plist_value "$plist" CFBundleShortVersionString)" == "$version" ]] ||
    die "the app reports version '$(plist_value "$plist" CFBundleShortVersionString)', expected '$version'"
  [[ "$(plist_value "$plist" CFBundleVersion)" == "$build" ]] ||
    die "the app reports build '$(plist_value "$plist" CFBundleVersion)', expected '$build'"

  [[ "$(archs_of "$main")" == "$expected_archs" ]] ||
    die "the app executable has architectures '$(archs_of "$main")', expected '$expected_archs'"
  [[ "$(archs_of "$EMBEDDED_SERVER")" == "$expected_archs" ]] ||
    die "the embedded server has architectures '$(archs_of "$EMBEDDED_SERVER")', expected '$expected_archs'"

  # --version prints and exits before the server reads any settings or opens anything.
  host="$(uname -m)"
  if [[ " $expected_archs " == *" $host "* ]]; then
    reported="$("$EMBEDDED_SERVER" --version)"
    [[ "$reported" == "benito-server $server_version" ]] ||
      die "the embedded server reports '$reported', expected 'benito-server $server_version'"
  else
    echo "note: this Mac ($host) cannot run the embedded server; skipped --version"
  fi
  if [[ "$host" == "arm64" && "$arch" == "universal" ]] && arch -x86_64 /usr/bin/true 2>/dev/null; then
    reported="$(arch -x86_64 "$EMBEDDED_SERVER" --version)"
    [[ "$reported" == "benito-server $server_version" ]] ||
      die "the Intel half of the embedded server reports '$reported', expected 'benito-server $server_version'"
  fi

  codesign --verify --deep --strict --verbose=2 "$APP"

  if ((!unsigned)); then
    bundle_id="$(plist_value "$plist" CFBundleIdentifier)"
    [[ -n "$bundle_id" && "$bundle_id" != org.example.* ]] ||
      die "the bundle id is '$bundle_id'. Set BENITO_BUNDLE_PREFIX (or apps/Benito/Config/Local.xcconfig) and never change it between releases"
    [[ "$(plist_value "$plist" SUPublicEDKey)" == "$BENITO_SPARKLE_PUBLIC_KEY" ]] ||
      die "SUPublicEDKey in the app is '$(plist_value "$plist" SUPublicEDKey)', not BENITO_SPARKLE_PUBLIC_KEY"
    [[ "$(plist_value "$plist" SUFeedURL)" == https://* ]] ||
      die "SUFeedURL in the app is '$(plist_value "$plist" SUFeedURL)'"
    for item in "$main" "$EMBEDDED_SERVER" "$APP/Contents/Frameworks/Sparkle.framework"; do
      [[ -e "$item" ]] || die "missing from the app: $item"
      has_hardened_runtime "$item" || die "no hardened runtime on $item"
      signed_by_team "$item" || die "$item is not signed by team $BENITO_TEAM_ID"
    done
    entitlements="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
    [[ "$entitlements" != *get-task-allow* ]] ||
      die "the app is signed with get-task-allow, which notarization rejects"
  fi
}

make_dmg() {
  local folder="$STAGE/dmg"
  step "creating $(basename "$DMG")"
  mkdir -p "$folder"
  ditto "$APP" "$folder/$APP_NAME.app"
  ln -s /Applications "$folder/Applications"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$folder" -fs HFS+ -format UDZO -ov "$DMG"
  if ((!unsigned)); then
    codesign --force --sign "$BENITO_DEVELOPER_ID" --timestamp "$DMG"
    codesign --verify --strict --verbose=2 "$DMG"
  fi
}

notarize_dmg() {
  local result="$OUT/notary-result.json" status id
  step "notarizing (this waits for Apple, usually a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$BENITO_NOTARY_PROFILE" \
    ${notary_keychain[@]+"${notary_keychain[@]}"} --wait --output-format json >"$result" ||
    die "notarytool submit failed; see $result"
  status="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    if [[ -n "$id" ]]; then
      xcrun notarytool log "$id" --keychain-profile "$BENITO_NOTARY_PROFILE" \
        ${notary_keychain[@]+"${notary_keychain[@]}"} >&2 || true
    fi
    die "notarization ended with status '${status:-unknown}'; see $result"
  fi
  echo "notarized: submission $id"

  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -t exec -vv "$APP"
}

# Proves the published signature against the key inside the app, with nothing from Sparkle: a
# release signed by the wrong private key would leave every installed copy unable to update.
verify_update_signature() {
  local signature=$1 script="$STAGE/verify-ed25519.swift"
  cat >"$script" <<'EOF'
import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4,
      let keyData = Data(base64Encoded: arguments[1]),
      let signature = Data(base64Encoded: arguments[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let archive = FileManager.default.contents(atPath: arguments[3])
else {
    exit(2)
}
exit(key.isValidSignature(signature, for: archive) ? 0 : 1)
EOF
  xcrun swift "$script" "$BENITO_SPARKLE_PUBLIC_KEY" "$signature" "$DMG" ||
    die "the update signature does not verify with BENITO_SPARKLE_PUBLIC_KEY; the private key used here is not the one the app trusts"
}

make_appcast() {
  local key_args=() notes_args=() signature
  step "writing the Sparkle appcast"
  [[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]] ||
    die "Sparkle's tools are not in $SPARKLE_BIN; run apps/BenitoServer/Scripts/fetch-sparkle.sh"
  if [[ -n "${BENITO_SPARKLE_KEY_FILE:-}" ]]; then
    key_args=(--ed-key-file "$BENITO_SPARKLE_KEY_FILE")
  fi
  if [[ -n "$release_page" ]]; then
    notes_args=(--full-release-notes-url "$release_page")
  fi

  # The folder holds only this release, so the feed lists only this release; Sparkle needs no more.
  "$SPARKLE_BIN/generate_appcast" ${key_args[@]+"${key_args[@]}"} \
    --download-url-prefix "$download_prefix" --link "$SITE_URL" \
    ${notes_args[@]+"${notes_args[@]}"} --maximum-deltas 0 -o "$APPCAST" "$DIST"
  [[ -f "$APPCAST" ]] || die "generate_appcast wrote no $APPCAST"

  signature="$("$SPARKLE_BIN/sign_update" ${key_args[@]+"${key_args[@]}"} -p "$DMG")"
  [[ -n "$signature" ]] || die "sign_update printed no signature"
  grep -qF -- "$signature" "$APPCAST" || die "the appcast does not carry the signature of $(basename "$DMG")"
  grep -qF "$download_prefix$(basename "$DMG")" "$APPCAST" || die "the appcast does not point at $download_prefix$(basename "$DMG")"
  verify_update_signature "$signature"
}

summary() {
  echo
  echo "Benito Server $version ($build), benito-server $server_version, $expected_archs"
  echo "app:      $APP ($(du -sh "$APP" | cut -f1))"
  echo "dmg:      $DMG ($(file_size "$DMG"))"
  echo "          sha256 $(file_sha256 "$DMG")"
  if [[ -f "$APPCAST" ]]; then
    echo "appcast:  $APPCAST ($(file_size "$APPCAST"))"
    echo "          sha256 $(file_sha256 "$APPCAST")"
  fi
  echo
  if ((unsigned)); then
    cat <<EOF
This is an unsigned dry run: ad-hoc signature, not notarized, no appcast. Do not publish it.
On this Mac it opens with: open "$APP"
EOF
    if [[ -x "$SPARKLE_BIN/generate_appcast" && -x "$SPARKLE_BIN/sign_update" ]]; then
      echo "Sparkle's tools are in place for a signed release: $SPARKLE_BIN"
    else
      echo "note: Sparkle's tools are not in $SPARKLE_BIN; a signed release needs apps/BenitoServer/Scripts/fetch-sparkle.sh to have run"
    fi
    return 0
  fi
  if ((skip_notarize)); then
    cat <<EOF
Notarization was skipped, so Gatekeeper will block this DMG on other Macs. Do not publish it,
and do not publish this appcast: its signature is for this exact file.
EOF
    return 0
  fi
  cat <<EOF
Left to do by hand (docs/release-mac.md):
  1. Tag the commit and push the tag:    git tag $TAG_PREFIX$version && git push origin $TAG_PREFIX$version
  2. Create the GitHub Release for that tag and attach $(basename "$DMG").
     The appcast expects it at:          $download_prefix$(basename "$DMG")
  3. Publish the feed:                   cp "$APPCAST" "$SITE_APPCAST", commit, push
  4. On a Mac with the previous version, choose Check for Updates and install.
EOF
}

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"

parse_args "$@"

notary_keychain=()
if [[ -n "${BENITO_NOTARY_KEYCHAIN:-}" ]]; then
  notary_keychain=(--keychain "$BENITO_NOTARY_KEYCHAIN")
fi
download_prefix=""
release_page=""

check_tools
if ((!unsigned)); then
  check_signing_prerequisites
fi

clean_staging
build_server
archive_app
sign_app
verify_app
make_dmg
if ((!unsigned)); then
  if ((!skip_notarize)); then
    notarize_dmg
  fi
  # After stapling: the staple changes the file, and the signature covers its exact bytes.
  make_appcast
fi
rm -rf "$STAGE/dmg" "$STAGE/verify-ed25519.swift"
summary
