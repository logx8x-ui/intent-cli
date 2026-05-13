#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="${1:-${HOME}/Applications/Intent.app}"
DETAILS="$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1 || true)"
REQUIREMENTS="$(codesign -dr - "$APP_BUNDLE" 2>&1 || true)"

grep -q 'Identifier=dev.loganmondi.intent' <<<"$DETAILS"
grep -q 'designated => identifier "dev.loganmondi.intent"' <<<"$REQUIREMENTS"

echo "Intent.app uses a stable local designated requirement"
