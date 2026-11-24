#!/bin/bash
# Fetch the pinned Sparkle release into apps/BenitoServer/Vendor/Sparkle (gitignored):
# Sparkle.framework for the app, and bin/ (generate_keys, generate_appcast, sign_update) for
# scripts/release-mac.sh. Runs as an Xcode pre-build phase and does nothing once it is in place.
#
# A release archive, not the Swift package: resolving the package's binary artifact makes
# xcodebuild ask the login keychain for github.com credentials, which hangs a build that has no
# one to answer the prompt.
set -euo pipefail

VERSION="2.10.1"
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
URL="https://github.com/sparkle-project/Sparkle/releases/download/${VERSION}/Sparkle-${VERSION}.tar.xz"

DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/Sparkle"
STAMP="$DEST/.version"

if [[ -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" && -d "$DEST/Sparkle.framework" ]]; then
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "Fetching Sparkle ${VERSION}"
curl --fail --silent --show-error --location --max-time 300 -o "$work/sparkle.tar.xz" "$URL"
actual="$(shasum -a 256 "$work/sparkle.tar.xz" | awk '{print $1}')"
if [[ "$actual" != "$SHA256" ]]; then
  echo "error: Sparkle ${VERSION} checksum mismatch (got $actual)" >&2
  exit 1
fi

mkdir "$work/out"
tar -xJf "$work/sparkle.tar.xz" -C "$work/out" ./Sparkle.framework ./bin ./LICENSE
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$work/out" "$DEST"
printf '%s\n' "$VERSION" >"$STAMP"
