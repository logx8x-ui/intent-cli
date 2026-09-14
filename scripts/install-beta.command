#!/bin/bash
set -euo pipefail
SOURCE="$(cd "$(dirname "$0")" && pwd)/Intent.app"
DEST="$HOME/Applications/Intent.app"
# This test hook only uses a caller-provided fixture directory; ordinary installs use HOME.
if [[ -n "${INTENT_INSTALL_TEST_ROOT:-}" ]]; then
  DEST="$INTENT_INSTALL_TEST_ROOT/Applications/Intent.app"
  STATE="$INTENT_INSTALL_TEST_ROOT/.intent"
  SYSTEM_APP="$INTENT_INSTALL_TEST_ROOT/SystemApplications/Intent.app"
else
  STATE="$HOME/.intent"
  SYSTEM_APP="/Applications/Intent.app"
fi
[[ -d "$SOURCE" ]] || { echo "Keep this installer beside Intent.app in the extracted kit."; exit 1; }
INSTALL_CMD=(/usr/bin/env)
if [[ -d "$SYSTEM_APP" && ! -d "$DEST" ]]; then
  DEST="$SYSTEM_APP"
  if [[ -z "${INTENT_INSTALL_TEST_ROOT:-}" ]]; then
    echo "Updating the existing system-wide Intent. macOS may ask for your administrator password."
    INSTALL_CMD=(sudo)
  fi
fi
FRESH=0
[[ -d "$DEST" ]] || FRESH=1
STAGED="${DEST}.installing"
mkdir -p "$(dirname "$DEST")" "$STATE"
chmod 700 "$STATE"
"${INSTALL_CMD[@]}" ditto "$SOURCE" "$STAGED"
codesign --verify --deep --strict "$STAGED"
if [[ -z "${INTENT_INSTALL_TEST_ROOT:-}" ]]; then pkill -u "$(id -u)" -x IntentApp 2>/dev/null || true; fi
# Keep a rollback copy until the new bundle has been moved successfully.
PREVIOUS="${DEST}.previous"
if [[ -d "$PREVIOUS" ]]; then echo "A previous install needs recovery: $PREVIOUS"; exit 1; fi
if [[ -d "$DEST" ]]; then "${INSTALL_CMD[@]}" mv "$DEST" "$PREVIOUS"; fi
if ! "${INSTALL_CMD[@]}" mv "$STAGED" "$DEST"; then [[ ! -d "$PREVIOUS" ]] || "${INSTALL_CMD[@]}" mv "$PREVIOUS" "$DEST"; exit 1; fi
if [[ "$FRESH" == 1 ]]; then touch "$STATE/reset-on-next-launch"; fi
# Only remove the obsolete application bundle, never user data during an update.
[[ ! -d "$PREVIOUS" ]] || "${INSTALL_CMD[@]}" rm -rf "$PREVIOUS"
if [[ -z "${INTENT_INSTALL_TEST_ROOT:-}" ]]; then open "$DEST"; fi
echo "Intent installed. Updates are automatic after this installation."
