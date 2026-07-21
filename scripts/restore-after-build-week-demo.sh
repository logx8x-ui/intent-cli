#!/usr/bin/env bash
set -euo pipefail

INTENT_DIR="$HOME/.intent"
INTENTIONS="$INTENT_DIR/intentions.json"
BACKUP="$INTENT_DIR/build-week-demo/intentions-before-demo.json"
APP="$HOME/Applications/Intent.app"

if [[ ! -f "$BACKUP" ]]; then
  echo "No Build Week canvas backup exists at $BACKUP." >&2
  exit 1
fi

if jq -e '.active == true' "$INTENT_DIR/browser-rules.json" >/dev/null 2>&1; then
  echo "Finish the active intention with Cmd+Shift+M before restoring." >&2
  exit 2
fi

cp "$BACKUP" "$INTENTIONS"
pkill -x IntentApp 2>/dev/null || true
sleep 1
if ! open -n "$APP"; then
  nohup "$APP/Contents/MacOS/IntentApp" >"$INTENT_DIR/build-week-demo/intent-app.log" 2>&1 &
fi
sleep 1
osascript -l JavaScript <<'JXA'
ObjC.import('Foundation')
$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
  'dev.loganmondi.intent.showOverlay', undefined, undefined, true
)
JXA

echo "Restored the full pre-demo Intent canvas."
