#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.4.0}"
BUILD_NUMBER="${2:-13}"
DIST="$ROOT/dist/release"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-release.XXXXXX")"
PKG_ROOT="$WORK/root"
PKG_SCRIPTS="$WORK/scripts"
DMG_ROOT="$WORK/dmg"
APP="$PKG_ROOT/Applications/Intent.app"
SUPPORT_DIR="$PKG_ROOT/Library/Application Support/Intent"
ARM_BUILD="$WORK/swift-arm64"
X86_BUILD="$WORK/swift-x86_64"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$SUPPORT_DIR"
mkdir -p "$PKG_ROOT/Library/LaunchAgents"
mkdir -p "$PKG_ROOT/Library/Application Support/Mozilla/NativeMessagingHosts"
mkdir -p "$PKG_ROOT/Library/Google/Chrome/NativeMessagingHosts"
mkdir -p "$PKG_SCRIPTS" "$DMG_ROOT/Browser Extensions" "$DIST"

cd "$ROOT"
for product in Intent IntentApp IntentNativeHost; do
  swift build -c release --scratch-path "$ARM_BUILD" --triple arm64-apple-macosx13.0 --product "$product"
  swift build -c release --scratch-path "$X86_BUILD" --triple x86_64-apple-macosx13.0 --product "$product"
done
npm run extension:build
npm run extension:build:chrome

lipo -create \
  "$ARM_BUILD/arm64-apple-macosx/release/IntentApp" \
  "$X86_BUILD/x86_64-apple-macosx/release/IntentApp" \
  -output "$APP/Contents/MacOS/IntentApp"
lipo -create \
  "$ARM_BUILD/arm64-apple-macosx/release/Intent" \
  "$X86_BUILD/x86_64-apple-macosx/release/Intent" \
  -output "$SUPPORT_DIR/Intent"
lipo -create \
  "$ARM_BUILD/arm64-apple-macosx/release/IntentNativeHost" \
  "$X86_BUILD/x86_64-apple-macosx/release/IntentNativeHost" \
  -output "$SUPPORT_DIR/IntentNativeHost"
cp -R "$ARM_BUILD/arm64-apple-macosx/release/Intent_IntentApp.bundle" "$APP/Contents/Resources/Intent_IntentApp.bundle"
chmod +x "$APP/Contents/MacOS/IntentApp" "$SUPPORT_DIR/Intent" "$SUPPORT_DIR/IntentNativeHost"

ICONSET="$WORK/Intent.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/Assets/IntentAppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/Assets/IntentAppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Intent.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>IntentApp</string>
  <key>CFBundleIdentifier</key><string>dev.loganmondi.intent</string>
  <key>CFBundleName</key><string>Intent</string>
  <key>CFBundleDisplayName</key><string>Intent</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>Intent</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

cat > "$PKG_ROOT/Library/LaunchAgents/dev.loganmondi.intent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.loganmondi.intent</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/Intent.app/Contents/MacOS/IntentApp</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

cat > "$PKG_ROOT/Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json" <<'JSON'
{
  "name": "intent_native_host",
  "description": "Intent browser rules native host",
  "path": "/Library/Application Support/Intent/IntentNativeHost",
  "type": "stdio",
  "allowed_extensions": ["intent-firefox@loganmondi.dev"]
}
JSON

cat > "$PKG_ROOT/Library/Google/Chrome/NativeMessagingHosts/intent_native_host.json" <<'JSON'
{
  "name": "intent_native_host",
  "description": "Intent browser rules native host",
  "path": "/Library/Application Support/Intent/IntentNativeHost",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://aibdbhjdckeeejpggfpfaghmomopjbpb/"]
}
JSON

cat > "$PKG_SCRIPTS/preinstall" <<'SCRIPT'
#!/bin/bash
pkill -x IntentApp 2>/dev/null || true
exit 0
SCRIPT

cat > "$PKG_SCRIPTS/postinstall" <<'SCRIPT'
#!/bin/bash
set -e
chmod +x "/Applications/Intent.app/Contents/MacOS/IntentApp"
chmod +x "/Library/Application Support/Intent/IntentNativeHost"
CONSOLE_USER="$(stat -f '%Su' /dev/console)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  USER_ID="$(id -u "$CONSOLE_USER")"
  launchctl bootout "gui/$USER_ID" /Library/LaunchAgents/dev.loganmondi.intent.plist 2>/dev/null || true
  launchctl bootstrap "gui/$USER_ID" /Library/LaunchAgents/dev.loganmondi.intent.plist 2>/dev/null || true
  launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" open -a "/Applications/Intent.app" || true
fi
exit 0
SCRIPT
chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

codesign \
  --force \
  --sign - \
  --identifier dev.loganmondi.intent \
  --requirements '=designated => identifier "dev.loganmondi.intent"' \
  "$APP" >/dev/null
xattr -cr "$PKG_ROOT"
dot_clean -m "$PKG_ROOT" >/dev/null 2>&1 || true

PKG="$DIST/Intent-${VERSION}.pkg"
DMG="$DIST/Intent-${VERSION}.dmg"
WORK_PKG="$WORK/Intent-${VERSION}.pkg"
WORK_DMG="$WORK/Intent-${VERSION}.dmg"
pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier dev.loganmondi.intent \
  --version "$VERSION" \
  --install-location / \
  "$WORK_PKG" >/dev/null

cp "$WORK_PKG" "$DMG_ROOT/Install Intent.pkg"
cp "$ROOT/dist/chrome/intent-browser-guard-chrome-0.1.2.zip" "$DMG_ROOT/Browser Extensions/Chrome - developer fallback.zip"
cp "$ROOT/dist/firefox/intent_browser_guard-0.1.6.zip" "$DMG_ROOT/Browser Extensions/Firefox - AMO upload source.zip"

cat > "$DMG_ROOT/README.txt" <<'TEXT'
INTENT BETA

1. Double-click “Install Intent.pkg”.
2. If macOS blocks it, Control-click the package, choose Open, then confirm.
3. Install Intent Browser Guard for your browser using the links in the GitHub README.
4. Open Intent from the menu-bar scope icon or press ~.

The extension ZIP files are included only as developer fallbacks while the store listings are under review.
TEXT

hdiutil create \
  -volname "Intent ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$WORK_DMG" >/dev/null

cp -f "$WORK_PKG" "$PKG"
cp -f "$WORK_DMG" "$DMG"

echo "$DMG"
