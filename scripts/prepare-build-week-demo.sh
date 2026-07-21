#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTENT_DIR="$HOME/.intent"
INTENTIONS="$INTENT_DIR/intentions.json"
DEMO_DIR="$INTENT_DIR/build-week-demo"
BACKUP="$DEMO_DIR/intentions-before-demo.json"
APP="$HOME/Applications/Intent.app"

if [[ ! -f "$INTENTIONS" ]]; then
  echo "Intent data was not found at $INTENTIONS." >&2
  exit 1
fi

mkdir -p "$DEMO_DIR"
if [[ ! -f "$BACKUP" ]]; then
  cp "$INTENTIONS" "$BACKUP"
  echo "Backed up the full canvas to $BACKUP"
fi

if jq -e '.active == true' "$INTENT_DIR/browser-rules.json" >/dev/null 2>&1; then
  echo "Finish the active intention with Cmd+Shift+M, then run this script again." >&2
  exit 2
fi

temporary="$(mktemp "$DEMO_DIR/intentions.XXXXXX")"
jq '
  map(select(.name == "Data Science" or .name == "Instagram replies" or .name == "Emails" or .name == "Imessages"))
  | map(
      if .name == "Data Science" then
        .graphPosition = {"x": 250, "y": -180}
        | .restrictionNodes = (.restrictionNodes | to_entries | map(
            .value.position = (if .key == 0 then {"x": 560, "y": -300} else {"x": 570, "y": 20} end)
            | .value
          ))
      elif .name == "Instagram replies" then
        .graphPosition = {"x": -360, "y": 100}
        | .restrictionNodes = (.restrictionNodes | map(.position = {"x": -70, "y": 70}))
        | .frictionNodes = (.frictionNodes | map(.position = {"x": -80, "y": 350}))
      elif .name == "Emails" then
        .graphPosition = {"x": 430, "y": 260}
      elif .name == "Imessages" then
        .graphPosition = {"x": -350, "y": -350}
        | .restrictionNodes = (.restrictionNodes | to_entries | map(
            .value.position = (if .key == 0 then {"x": -650, "y": -390} else {"x": -650, "y": -220} end)
            | .value
          ))
      else . end
    )
' "$INTENTIONS" > "$temporary"

jq -e 'length == 4' "$temporary" >/dev/null || {
  rm -f "$temporary"
  echo "The four demo intentions were not all found. Your canvas was not changed." >&2
  exit 3
}

mv "$temporary" "$INTENTIONS"
pkill -x IntentApp 2>/dev/null || true
sleep 1
if ! open -n "$APP"; then
  nohup "$APP/Contents/MacOS/IntentApp" >"$DEMO_DIR/intent-app.log" 2>&1 &
fi
sleep 1
osascript -l JavaScript <<'JXA'
ObjC.import('Foundation')
$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately(
  'dev.loganmondi.intent.showOverlay', undefined, undefined, true
)
JXA

printf '\nDemo canvas is ready.\n\n'
printf 'Script: %s\n' "$ROOT/docs/build-week-demo.md"
printf 'Restore later: %s\n' "$ROOT/scripts/restore-after-build-week-demo.sh"
printf '\nDo a 20-second audio test before the real take.\n'
