#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.intent/bin"
APPLICATIONS_DIR="${HOME}/Applications"
APP_BUNDLE="${APPLICATIONS_DIR}/Intent.app"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
LAUNCH_AGENT_FILE="${LAUNCH_AGENTS_DIR}/dev.loganmondi.intent.plist"

cd "$ROOT"
swift build -c release --product Intent
swift build -c release --product IntentApp
swift build -c release --product IntentNativeHost

atomic_install_executable() {
  local source="$1"
  local destination="$2"
  local temporary="${destination}.new.$$"
  cp "$source" "$temporary"
  chmod +x "$temporary"
  mv -f "$temporary" "$destination"
}

pkill -x IntentApp 2>/dev/null || true

mkdir -p "$BIN_DIR"
mkdir -p "$APP_DIR"
atomic_install_executable "$ROOT/.build/release/Intent" "$APP_DIR/Intent"
atomic_install_executable "$ROOT/.build/release/IntentApp" "$APP_DIR/IntentApp"
atomic_install_executable "$ROOT/.build/release/IntentNativeHost" "$APP_DIR/IntentNativeHost"
pkill -f "^${APP_DIR}/IntentNativeHost" 2>/dev/null || true

ln -sf "$APP_DIR/Intent" "$BIN_DIR/Intent"
ln -sf "$APP_DIR/Intent" "$BIN_DIR/intent"
ln -sf "$APP_DIR/IntentApp" "$BIN_DIR/IntentApp"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
atomic_install_executable "$APP_DIR/IntentApp" "$APP_BUNDLE/Contents/MacOS/IntentApp"
/usr/bin/ditto "$ROOT/.build/release/Intent_IntentApp.bundle" "$APP_BUNDLE/Contents/Resources/Intent_IntentApp.bundle"
cp "$ROOT/Assets/Intent.icns" "$APP_BUNDLE/Contents/Resources/Intent.icns"
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
  <key>CFBundleIconFile</key>
  <string>Intent</string>
  <key>CFBundleShortVersionString</key>
  <string>0.7.0</string>
  <key>CFBundleVersion</key>
  <string>19</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign \
  --force \
  --sign - \
  --identifier dev.loganmondi.intent \
  --requirements '=designated => identifier "dev.loganmondi.intent"' \
  "$APP_BUNDLE" >/dev/null
mdimport "$APP_BUNDLE" 2>/dev/null || true

rm -f "$BIN_DIR/intent-app"
cat > "$BIN_DIR/intent-app" <<LAUNCHER
#!/usr/bin/env bash
open "$APP_BUNDLE"
LAUNCHER
chmod +x "$BIN_DIR/intent-app"

mkdir -p "$LAUNCH_AGENTS_DIR"
cat > "$LAUNCH_AGENT_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>dev.loganmondi.intent</string>
  <key>ProgramArguments</key>
  <array>
    <string>${APP_BUNDLE}/Contents/MacOS/IntentApp</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)" "$LAUNCH_AGENT_FILE" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENT_FILE" 2>/dev/null || true

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
echo "Installed Intent as a login menu-bar app via $LAUNCH_AGENT_FILE"
echo "Installed Firefox native host manifest to $HOST_FILE"

CHROME_HOST_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
CHROME_HOST_FILE="${CHROME_HOST_DIR}/intent_native_host.json"
mkdir -p "$CHROME_HOST_DIR"
cat > "$CHROME_HOST_FILE" <<JSON
{
  "name": "intent_native_host",
  "description": "Intent browser rules native host",
  "path": "${APP_DIR}/IntentNativeHost",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://aibdbhjdckeeejpggfpfaghmomopjbpb/"
  ]
}
JSON
echo "Installed Chrome native host manifest to $CHROME_HOST_FILE"

if [[ -w /opt/homebrew/bin ]]; then
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/Intent
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/intent
  ln -sf "$APP_DIR/IntentApp" /opt/homebrew/bin/IntentApp
  ln -sf "$BIN_DIR/intent-app" /opt/homebrew/bin/intent-app
  echo "Also linked Intent, intent, IntentApp, and intent-app to /opt/homebrew/bin"
elif [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Make sure $BIN_DIR is on your PATH."
fi
