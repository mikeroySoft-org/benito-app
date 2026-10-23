#!/usr/bin/env bash
# Relaunch Benito on a paired iPhone with its console attached and stream BenitoLog output.
#
# macOS `log stream` cannot read from iOS devices, and `log collect --device` needs root, so this
# uses `devicectl ... --console` with OS_ACTIVITY_DT_MODE=YES (what Xcode does): OSLog messages at
# .notice and above are mirrored to the app's stderr and relayed here.
#
# Env:
#   DEVICE=<name|udid|coredevice id>  device to use (default: first available paired iPhone)
#   BENITO_LOG_ALL=1                  also show framework noise (default: BenitoLog categories only)
#
# Stopping this script (Ctrl-C) forwards the signal and terminates the app on the phone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/.debug"
OUT="$OUT_DIR/device.log"
BUNDLE_ID="com.mikeroysoft.benito"
mkdir -p "$OUT_DIR"

DEVICE="${DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
  DEVICE="$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone/ && (/available \(paired\)/ || / connected /) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F-]{27}$/) { print $i; exit } }')"
fi
if [[ -z "$DEVICE" ]]; then
  echo "No available/connected paired iPhone found (xcrun devicectl list devices). Set DEVICE=<name|id>." >&2
  exit 1
fi

# BenitoLog lines look like: Benito[pid:tid] [sync] connect https://…
FILTER='\[(api|sync|store|ui)\]'
[[ "${BENITO_LOG_ALL:-}" == "1" ]] && FILTER='.'

echo "Relaunching $BUNDLE_ID on $DEVICE with console attached (tee → $OUT). Ctrl-C stops the app."
xcrun devicectl device process launch \
  --device "$DEVICE" \
  --terminate-existing \
  --console \
  -e '{"OS_ACTIVITY_DT_MODE":"YES"}' \
  "$BUNDLE_ID" 2>&1 \
  | tee -a "$OUT" \
  | grep --line-buffered -E "$FILTER"
