#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.intent/bin"
APPLICATIONS_DIR="${HOME}/Applications"
APP_BUNDLE="${APPLICATIONS_DIR}/Intent.app"

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

mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$APP_DIR/IntentApp" "$APP_BUNDLE/Contents/MacOS/IntentApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/IntentApp"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>IntentApp</string>
  <key>CFBundleIdentifier</key>
  <string>dev.loganmondi.intent</string>
  <key>CFBundleName</key>
  <string>Intent</string>
  <key>CFBundleDisplayName</key>
  <string>Intent</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
mdimport "$APP_BUNDLE" 2>/dev/null || true

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
echo "Installed Intent.app to $APP_BUNDLE"
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
