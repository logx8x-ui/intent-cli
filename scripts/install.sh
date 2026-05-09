#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.intent/bin"

cd "$ROOT"
swift build -c release --product Intent
swift build -c release --product IntentApp
swift build -c release --product IntentNativeHost

mkdir -p "$BIN_DIR"
mkdir -p "$APP_DIR"
cp "$ROOT/.build/release/Intent" "$APP_DIR/Intent"
cp "$ROOT/.build/release/IntentApp" "$APP_DIR/IntentApp"
cp "$ROOT/.build/release/IntentNativeHost" "$APP_DIR/IntentNativeHost"
chmod +x "$APP_DIR/Intent"
chmod +x "$APP_DIR/IntentApp"
chmod +x "$APP_DIR/IntentNativeHost"

ln -sf "$APP_DIR/Intent" "$BIN_DIR/Intent"
ln -sf "$APP_DIR/Intent" "$BIN_DIR/intent"
ln -sf "$APP_DIR/IntentApp" "$BIN_DIR/IntentApp"
ln -sf "$APP_DIR/IntentApp" "$BIN_DIR/intent-app"

HOST_DIR="${HOME}/Library/Application Support/Mozilla/NativeMessagingHosts"
HOST_FILE="${HOST_DIR}/intent_native_host.json"
mkdir -p "$HOST_DIR"
cat > "$HOST_FILE" <<JSON
{
  "name": "intent_native_host",
  "description": "Intent browser rules native host",
  "path": "${APP_DIR}/IntentNativeHost",
  "type": "stdio",
  "allowed_extensions": [
    "intent-firefox@loganmondi.dev"
  ]
}
JSON

echo "Installed Intent, IntentApp, and intent-app to $BIN_DIR"
echo "Installed Firefox native host manifest to $HOST_FILE"

if [[ -w /opt/homebrew/bin ]]; then
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/Intent
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/intent
  ln -sf "$APP_DIR/IntentApp" /opt/homebrew/bin/IntentApp
  ln -sf "$APP_DIR/IntentApp" /opt/homebrew/bin/intent-app
  echo "Also linked Intent, intent, IntentApp, and intent-app to /opt/homebrew/bin"
elif [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Make sure $BIN_DIR is on your PATH."
fi
