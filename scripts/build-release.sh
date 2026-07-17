#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.5.0}"
BUILD_NUMBER="${2:-14}"
DIST="$ROOT/dist/release"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-release.XXXXXX")"
PKG_ROOT="$WORK/root"
PKG_SCRIPTS="$WORK/scripts"
DMG_ROOT="$WORK/dmg"
APP="$PKG_ROOT/Applications/Intent.app"
SUPPORT_DIR="$PKG_ROOT/Library/Application Support/Intent"
ARM_BUILD="$WORK/swift-arm64"
X86_BUILD="$WORK/swift-x86_64"
APPLICATION_IDENTITY="${INTENT_APPLICATION_IDENTITY:-}"
INSTALLER_IDENTITY="${INTENT_INSTALLER_IDENTITY:-}"
NOTARY_PROFILE="${INTENT_NOTARY_PROFILE:-}"
REQUIRE_NOTARIZATION="${INTENT_REQUIRE_NOTARIZATION:-0}"

if [[ "$REQUIRE_NOTARIZATION" == "1" ]] && {
  [[ -z "$APPLICATION_IDENTITY" ]] || [[ -z "$INSTALLER_IDENTITY" ]] || [[ -z "$NOTARY_PROFILE" ]]
}; then
  cat >&2 <<'MSG'
Public release refused: Apple signing and notarization are not configured.

Set:
  INTENT_APPLICATION_IDENTITY='Developer ID Application: ...'
  INTENT_INSTALLER_IDENTITY='Developer ID Installer: ...'
  INTENT_NOTARY_PROFILE='intent-notary'

Apple Developer Program membership and installed Developer ID certificates are required.
MSG
  exit 4
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$SUPPORT_DIR"
mkdir -p "$PKG_ROOT/Library/LaunchAgents"
mkdir -p "$PKG_ROOT/Library/Application Support/Mozilla/NativeMessagingHosts"
mkdir -p "$PKG_ROOT/Library/Google/Chrome/NativeMessagingHosts"
rm -rf "$DIST"
mkdir -p "$PKG_SCRIPTS" "$DMG_ROOT" "$DIST"

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

if [[ -n "$APPLICATION_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$SUPPORT_DIR/Intent"
  codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$SUPPORT_DIR/IntentNativeHost"
  codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$APP/Contents/MacOS/IntentApp"
  codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  codesign \
    --force \
    --sign - \
    --identifier dev.loganmondi.intent \
    --requirements '=designated => identifier "dev.loganmondi.intent"' \
    "$APP" >/dev/null
fi
xattr -cr "$PKG_ROOT"
dot_clean -m "$PKG_ROOT" >/dev/null 2>&1 || true

DMG="$DIST/Intent.dmg"
UNSIGNED_PKG="$WORK/Intent-${VERSION}-unsigned.pkg"
WORK_PKG="$WORK/Intent-${VERSION}.pkg"
WORK_DMG="$WORK/Intent-${VERSION}.dmg"
pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier dev.loganmondi.intent \
  --version "$VERSION" \
  --install-location / \
  "$UNSIGNED_PKG" >/dev/null

if [[ -n "$INSTALLER_IDENTITY" ]]; then
  productsign --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$WORK_PKG" >/dev/null
  pkgutil --check-signature "$WORK_PKG"
else
  mv "$UNSIGNED_PKG" "$WORK_PKG"
fi

cp "$WORK_PKG" "$DMG_ROOT/Install Intent.pkg"

hdiutil create \
  -volname "Intent ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$WORK_DMG" >/dev/null

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ -z "$APPLICATION_IDENTITY" || -z "$INSTALLER_IDENTITY" ]]; then
    echo "Notarization requires both INTENT_APPLICATION_IDENTITY and INTENT_INSTALLER_IDENTITY." >&2
    exit 3
  fi
  xcrun notarytool submit "$WORK_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORK_DMG"
  xcrun stapler validate "$WORK_DMG"
else
  echo "Warning: built a local beta DMG without Apple notarization." >&2
fi

cp -f "$WORK_DMG" "$DMG"

FIREFOX_VERSION="$(node -p "require('$ROOT/firefox-extension/manifest.json').version")"
CHROME_VERSION="$(node -p "require('$ROOT/chrome-extension/manifest.json').version")"
cp -f "$ROOT/dist/firefox/intent_browser_guard-${FIREFOX_VERSION}.zip" "$DIST/Intent-Firefox-Extension.zip"
cp -f "$ROOT/dist/chrome/intent-browser-guard-chrome-${CHROME_VERSION}.zip" "$DIST/Intent-Chrome-Extension.zip"

printf '%s\n' \
  "$DMG" \
  "$DIST/Intent-Firefox-Extension.zip" \
  "$DIST/Intent-Chrome-Extension.zip"
