#!/bin/bash
# Xcode build phase: put benito-server next to the app's executable (Contents/MacOS), where
# Bundle.main.url(forAuxiliaryExecutable:) finds it and the app's signature covers it.
#
# BENITO_SERVER_BINARY=<file> embeds that file (scripts/release-mac.sh passes a universal build).
# Otherwise the server is built here with cargo for the Mac doing the build.
set -euo pipefail

SERVER_DIR="${SRCROOT}/../../server"
DEST="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_FOLDER_PATH}/benito-server"

if [[ -n "${BENITO_SERVER_BINARY:-}" ]]; then
  [[ -f "$BENITO_SERVER_BINARY" ]] || {
    echo "error: BENITO_SERVER_BINARY is not a file: $BENITO_SERVER_BINARY" >&2
    exit 1
  }
  SOURCE="$BENITO_SERVER_BINARY"
else
  # Xcode's PATH has no ~/.cargo/bin.
  export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
  command -v cargo >/dev/null 2>&1 || {
    echo "error: cargo not found; install Rust from https://rustup.rs or set BENITO_SERVER_BINARY" >&2
    exit 1
  }
  if [[ "${CONFIGURATION}" == "Release" ]]; then
    (cd "$SERVER_DIR" && cargo build --locked --release)
    SOURCE="$SERVER_DIR/target/release/benito-server"
  else
    (cd "$SERVER_DIR" && cargo build --locked)
    SOURCE="$SERVER_DIR/target/debug/benito-server"
  fi
fi

mkdir -p "$(dirname "$DEST")"
cp -f "$SOURCE" "$DEST"
chmod 755 "$DEST"

# Nested code is signed before the app; the hardened runtime is required for notarization.
if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime ${OTHER_CODE_SIGN_FLAGS:-} \
    --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST"
fi
