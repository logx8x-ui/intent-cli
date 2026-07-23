#!/usr/bin/env bash
set -euo pipefail

APP="${1:-/Applications/Intent.app}"
TOGGLES="${2:-100}"
[[ -x "$APP/Contents/MacOS/IntentApp" ]] || { echo "Intent is not installed at $APP" >&2; exit 1; }

pkill -x IntentApp 2>/dev/null || true
open -n "$APP"
sleep 2
PID="$(pgrep -x IntentApp | head -1)"
[[ -n "$PID" ]] || { echo "Intent did not launch." >&2; exit 2; }

for ((index = 0; index < TOGGLES; index++)); do
  /usr/bin/osascript -l JavaScript -e \
    'ObjC.import("Foundation"); $.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately("dev.loganmondi.intent.showOverlay", null, null, true);'
  sleep 0.04
  kill -0 "$PID"
done

echo "Intent survived $TOGGLES overlay requests (PID $PID)."
