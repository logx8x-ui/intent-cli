#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.9.3}"
BUILD_NUMBER="${2:-202610110001}"
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
ALLOW_UNSIGNED_LOCAL="${INTENT_ALLOW_UNSIGNED_LOCAL:-0}"
TESTER_PRERELEASE="${INTENT_TESTER_PRERELEASE:-0}"
CURRENT_ARM_TESTER="${INTENT_TESTER_USE_CURRENT_ARM_BUILD:-0}"
RELEASE_ARCHITECTURE="${INTENT_RELEASE_ARCHITECTURE:-arm64}"
case "$RELEASE_ARCHITECTURE" in
  arm64) ARCHITECTURES='["arm64"]' ;;
  universal) ARCHITECTURES='["arm64", "x86_64"]' ;;
  *) echo "Use INTENT_RELEASE_ARCHITECTURE=arm64 or universal." >&2; exit 4 ;;
esac
SIGNED_FIREFOX_INPUT="${INTENT_SIGNED_FIREFOX_XPI:-}"
SIGNED_FIREFOX_SHA="${INTENT_SIGNED_FIREFOX_SHA256:-}"
if [[ "$TESTER_PRERELEASE" == "1" ]]; then
  ALLOW_UNSIGNED_LOCAL=1
  DIST="$ROOT/dist/tester-release"
fi
if [[ "$CURRENT_ARM_TESTER" == "1" ]]; then
  [[ "$TESTER_PRERELEASE" == "1" ]] || { echo "Existing binaries are allowed only for an explicit tester prerelease." >&2; exit 4; }
  ARM_BUILD="${INTENT_LAUNCH_BUILD_PATH:-$ROOT/.build-launch}"
  ARCHITECTURES='["arm64"]'
  RELEASE_ARCHITECTURE=arm64
fi
DIST="${INTENT_RELEASE_OUTPUT:-$DIST}"
MINIMUM_MACOS="13.0"
BUILD_CHANNEL="launch"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "Use a stable version and numeric build number." >&2; exit 4; }
GOOGLE_CLIENT_SECRET="${INTENT_GOOGLE_CLIENT_SECRET:-}"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SOURCE_FINGERPRINT="$(cd "$ROOT" && node -e 'console.log(require("./scripts/change-impact.cjs").sourceFingerprint(process.cwd()))')"
SOURCE_DIRTY="$(cd "$ROOT" && node -e 'console.log(require("./scripts/change-impact.cjs").changedPaths(process.cwd()).length > 0)')"
if [[ -e "$DIST" && ( ! -d "$DIST" || -n "$(ls -A "$DIST")" ) ]]; then
  echo 'Release output is not empty. Preserve it and set INTENT_RELEASE_OUTPUT to a new immutable build directory.' >&2
  exit 4
fi

if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]] && {
  [[ -z "$APPLICATION_IDENTITY" ]] || [[ -z "$INSTALLER_IDENTITY" ]] || [[ -z "$NOTARY_PROFILE" ]]
}; then
  cat >&2 <<'MSG'
Release refused: Apple signing and notarization are not configured.

Set:
  INTENT_APPLICATION_IDENTITY='Developer ID Application: ...'
  INTENT_INSTALLER_IDENTITY='Developer ID Installer: ...'
  INTENT_NOTARY_PROFILE='intent-notary'

Apple Developer Program membership and installed Developer ID certificates are required.

For a clearly labelled, non-distributable local QA build only:
  INTENT_ALLOW_UNSIGNED_LOCAL=1 ./scripts/build-release.sh
MSG
  exit 4
fi
if [[ -z "$GOOGLE_CLIENT_SECRET" && "$TESTER_PRERELEASE" != "1" ]]; then
  GOOGLE_CLIENT_SECRET="$(
    security find-generic-password \
      -s "dev.loganmondi.intent.build" \
      -a "google-oauth-client-secret" \
      -w 2>/dev/null || true
  )"
fi

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$SUPPORT_DIR"
mkdir -p "$PKG_ROOT/Library/Application Support/Mozilla/NativeMessagingHosts"
mkdir -p "$PKG_ROOT/Library/Google/Chrome/NativeMessagingHosts"
# Preserve supplied signed input even when the operator points at a prior
# release directory. Validate before creating any new output.
if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" && -n "$SIGNED_FIREFOX_INPUT" ]]; then
  /usr/bin/python3 "$ROOT/scripts/verify-signed-firefox.py" \
    "$SIGNED_FIREFOX_INPUT" "$ROOT/firefox-extension" "$SIGNED_FIREFOX_SHA"
  cp "$SIGNED_FIREFOX_INPUT" "$WORK/verified-firefox.xpi"
fi
mkdir -p "$PKG_SCRIPTS" "$DMG_ROOT" "$DIST"

cd "$ROOT"
if [[ "$CURRENT_ARM_TESTER" != "1" ]]; then
for product in Intent IntentApp IntentNativeHost; do
  swift build --jobs 2 --disable-sandbox -c release --scratch-path "$ARM_BUILD" --triple "arm64-apple-macosx${MINIMUM_MACOS}" --product "$product"
  if [[ "$RELEASE_ARCHITECTURE" == universal ]]; then
  swift build --jobs 2 --disable-sandbox -c release --scratch-path "$X86_BUILD" --triple "x86_64-apple-macosx${MINIMUM_MACOS}" --product "$product"
  fi
done
fi
if [[ "$CURRENT_ARM_TESTER" == "1" ]]; then
  # Old executables do not recognize this diagnostic and would open the app.
  # Require the side-effect-free entry point before querying any reused binary.
  if ! /usr/bin/python3 - "$ARM_BUILD/arm64-apple-macosx/release/IntentApp" <<'MARKER'
import pathlib, sys
sys.exit(0 if b'--print-build-channel' in pathlib.Path(sys.argv[1]).read_bytes() else 1)
MARKER
  then
    echo "Refusing an older executable without the safe build-channel diagnostic." >&2; exit 4
  fi
  if [[ "$("$ARM_BUILD/arm64-apple-macosx/release/IntentApp" --print-build-channel)" != "$BUILD_CHANNEL" ]]; then
    echo "Refusing to package a development executable as the launch channel. Build the launch candidate first." >&2; exit 4
  fi
fi
if [[ "$ALLOW_UNSIGNED_LOCAL" == "1" ]]; then
  npm run extension:build
else
  if [[ -z "$SIGNED_FIREFOX_INPUT" ]]; then
    # AMO signing remains available, but never delete an approved archive while
    # obtaining another. Require exactly one matching output afterwards.
    "$ROOT/scripts/sign-firefox-extension.sh"
    FIREFOX_SOURCE="$(/usr/bin/python3 - "$ROOT/dist/firefox" "$ROOT/firefox-extension/manifest.json" <<'XPI'
import json, pathlib, sys, zipfile
version=json.load(open(sys.argv[2]))['version']
matches=[]
for path in pathlib.Path(sys.argv[1]).glob('*.xpi'):
    with zipfile.ZipFile(path) as archive:
        if json.loads(archive.read('manifest.json')).get('version') == version:
            matches.append(path)
if len(matches) != 1:
    sys.exit('Choose the approved signed archive with INTENT_SIGNED_FIREFOX_XPI and its recorded SHA256.')
print(matches[0])
XPI
)"
    SIGNED_FIREFOX_SHA="$(shasum -a 256 "$FIREFOX_SOURCE" | awk '{print $1}')"
    /usr/bin/python3 "$ROOT/scripts/verify-signed-firefox.py" \
      "$FIREFOX_SOURCE" "$ROOT/firefox-extension" "$SIGNED_FIREFOX_SHA"
    cp "$FIREFOX_SOURCE" "$WORK/verified-firefox.xpi"
  fi
fi
npm run extension:build:chrome
FIREFOX_VERSION="$(node -p "require('$ROOT/firefox-extension/manifest.json').version")"
CHROME_VERSION="$(node -p "require('$ROOT/chrome-extension/manifest.json').version")"
PUBLISHED_CHROME_VERSION="${INTENT_CHROME_WEB_STORE_VERSION:-}"
CHROME_STORE_URL="https://chromewebstore.google.com/detail/intent-browser-guard/ffgfjfpkddgimambgmahlodjjojmjnbc"
CHROME_APPROVED=false
PUBLISHED_CHROME_SETUP_VERSION=""
if [[ "${INTENT_CHROME_WEB_STORE_APPROVED:-0}" == "1" && "$PUBLISHED_CHROME_VERSION" == "$CHROME_VERSION" ]]; then
  CHROME_APPROVED=true
  PUBLISHED_CHROME_SETUP_VERSION="$PUBLISHED_CHROME_VERSION"
fi
if [[ -n "$PUBLISHED_CHROME_VERSION" && "$PUBLISHED_CHROME_VERSION" != "$CHROME_VERSION" ]]; then
  echo "Release refused: the Chrome store version does not match this build." >&2; exit 6
fi
if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
  FIREFOX_SOURCE="$WORK/verified-firefox.xpi"
  [[ -n "$FIREFOX_SOURCE" ]] || { echo "Release refused: Mozilla did not return a signed Firefox extension." >&2; exit 6; }
  /usr/bin/python3 - "$FIREFOX_SOURCE" "$FIREFOX_VERSION" <<'CHECK'
import json, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    if json.loads(z.read('manifest.json'))['version'] != sys.argv[2] or 'META-INF/mozilla.rsa' not in z.namelist():
        sys.exit('Release refused: Firefox signature/version does not match this build.')
CHECK
  mkdir -p "$APP/Contents/Resources/BrowserGuard"
  cp "$FIREFOX_SOURCE" "$APP/Contents/Resources/BrowserGuard/Intent-Firefox-Extension.xpi"
fi

if [[ "$RELEASE_ARCHITECTURE" == arm64 ]]; then
  cp "$ARM_BUILD/arm64-apple-macosx/release/IntentApp" "$APP/Contents/MacOS/IntentApp"
  cp "$ARM_BUILD/arm64-apple-macosx/release/Intent" "$SUPPORT_DIR/Intent"
  cp "$ARM_BUILD/arm64-apple-macosx/release/IntentNativeHost" "$SUPPORT_DIR/IntentNativeHost"
else
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
fi
cp -R "$ARM_BUILD/arm64-apple-macosx/release/Intent_IntentApp.bundle" "$APP/Contents/Resources/Intent_IntentApp.bundle"
"$ROOT/scripts/configure-supabase-bundle.sh" \
  "$APP/Contents/Resources/Intent_IntentApp.bundle" \
  "$([[ "$ALLOW_UNSIGNED_LOCAL" == "1" ]] && echo 0 || echo 1)"
chmod +x "$APP/Contents/MacOS/IntentApp" "$SUPPORT_DIR/Intent" "$SUPPORT_DIR/IntentNativeHost"

cp "$ROOT/Assets/Intent.icns" "$APP/Contents/Resources/Intent.icns"

if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_CONFIG="$APP/Contents/Resources/GoogleCalendarConfig.plist"
  cp "$ROOT/Sources/IntentApp/Resources/GoogleCalendarConfig.plist" "$GOOGLE_CONFIG"
  /usr/libexec/PlistBuddy -c "Delete :CLIENT_SECRET" "$GOOGLE_CONFIG" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CLIENT_SECRET string $GOOGLE_CLIENT_SECRET" "$GOOGLE_CONFIG"
elif [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
  cat >&2 <<'MSG'
Release refused: Google Calendar OAuth is missing its protected client secret.

Store it in Keychain:
  security add-generic-password \
    -U \
    -s 'dev.loganmondi.intent.build' \
    -a 'google-oauth-client-secret' \
    -w

Or set INTENT_GOOGLE_CLIENT_SECRET for this build.
MSG
  exit 5
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>IntentApp</string>
  <key>CFBundleIdentifier</key><string>dev.loganmondi.intent</string>
  <key>CFBundleName</key><string>Intent</string>
  <key>CFBundleDisplayName</key><string>Intent</string>
  <key>IntentBuildChannel</key><string>${BUILD_CHANNEL}</string>
  <key>IntentDevelopmentBuild</key><false/>
  <key>IntentChromePublishedGuardVersion</key><string>${PUBLISHED_CHROME_SETUP_VERSION}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>Intent</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>dev.loganmondi.intent.auth</string>
      <key>CFBundleURLSchemes</key>
      <array><string>intent</string></array>
    </dict>
  </array>
  <key>LSMinimumSystemVersion</key><string>${MINIMUM_MACOS}</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Intent uses the microphone only while you speak your purpose in Purpose Mode.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Intent turns your spoken purpose into text so it can start the right focused session.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>Intent can show your calendars beside local schedules and optionally mirror linked Intent sessions. Calendar access is requested only when you choose Connect.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>Intent can show your calendars beside local schedules and optionally mirror linked Intent sessions. Calendar access is requested only when you choose Connect.</string>
  <key>NSRemindersUsageDescription</key>
  <string>Intent can optionally show Reminders in a separate area of the scheduler. Reminder access is requested only when you enable it.</string>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>Intent can optionally show Reminders in a separate area of the scheduler. Reminder access is requested only when you enable it.</string>
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
  "allowed_origins": [
    "chrome-extension://aibdbhjdckeeejpggfpfaghmomopjbpb/",
    "chrome-extension://ffgfjfpkddgimambgmahlodjjojmjnbc/"
  ]
}
JSON

sed -e "s/^RELEASE_ARCHITECTURE=.*/RELEASE_ARCHITECTURE=$RELEASE_ARCHITECTURE/" \
  -e "s/^MINIMUM_MACOS_MAJOR=.*/MINIMUM_MACOS_MAJOR=${MINIMUM_MACOS%%.*}/" \
  "$ROOT/scripts/package-preinstall.sh" > "$PKG_SCRIPTS/preinstall"

cp "$ROOT/scripts/package-postinstall.sh" "$PKG_SCRIPTS/postinstall"
chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"

"$ROOT/scripts/embed-update-components.sh" "$APP" "$ARM_BUILD"
[[ "$("$APP/Contents/MacOS/IntentApp" --print-build-channel)" == "$BUILD_CHANNEL" ]] || {
  echo "Release refused: compiled executable is not the launch channel." >&2; exit 4;
}
cp "$SUPPORT_DIR/IntentNativeHost" "$APP/Contents/Helpers/IntentNativeHost"

if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
  codesign --force --deep --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$APPLICATION_IDENTITY" "$APP/Contents/Helpers/IntentNativeHost"
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

if [[ "$TESTER_PRERELEASE" == "1" ]]; then
  DMG="$DIST/Intent-Tester-unsigned.dmg"
elif [[ "$ALLOW_UNSIGNED_LOCAL" == "1" ]]; then
  DMG="$DIST/Intent-local-unsigned.dmg"
else
  DMG="$DIST/Intent.dmg"
fi
WORK_DMG="$WORK/Intent-${VERSION}.dmg"
pkgbuild --analyze --root "$PKG_ROOT" "$WORK/components.plist" >/dev/null
/usr/bin/python3 "$ROOT/scripts/package-component-policy.py" \
  "$WORK/components.plist" "$WORK/components-fixed.plist"
# Every variant packages the same signed app bytes. Only the postinstall's
# validated browser enum differs; each resulting package gets its own ticket.
for choice in firefox chrome both; do
  case "$choice" in firefox) label=Firefox ;; chrome) label=Chrome ;; both) label=Both ;; esac
  sed "s/^SETUP_BROWSER_CHOICE=.*/SETUP_BROWSER_CHOICE=$choice/" \
    "$ROOT/scripts/package-postinstall.sh" > "$PKG_SCRIPTS/postinstall"
  chmod +x "$PKG_SCRIPTS/postinstall"
  UNSIGNED_PKG="$WORK/Intent-${choice}-unsigned.pkg"
  WORK_PKG="$WORK/Intent-${choice}.pkg"
  pkgbuild \
    --root "$PKG_ROOT" \
    --component-plist "$WORK/components-fixed.plist" \
    --scripts "$PKG_SCRIPTS" \
    --identifier dev.loganmondi.intent \
    --version "$VERSION" \
    --install-location / \
    "$UNSIGNED_PKG" >/dev/null
  if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
    productsign --sign "$INSTALLER_IDENTITY" "$UNSIGNED_PKG" "$WORK_PKG" >/dev/null
    pkgutil --check-signature "$WORK_PKG"
    xcrun notarytool submit "$WORK_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$WORK_PKG"
    xcrun stapler validate "$WORK_PKG"
    spctl --assess --type install --verbose=2 "$WORK_PKG"
  else
    mv "$UNSIGNED_PKG" "$WORK_PKG"
  fi
  cp "$WORK_PKG" "$DIST/Intent-${label}.pkg"
  if [[ "$choice" == both ]]; then
    cp "$WORK_PKG" "$DMG_ROOT/Install Intent.pkg"
  fi
done

hdiutil create \
  -volname "Intent ${VERSION}" \
  -srcfolder "$DMG_ROOT" \
  -ov \
  -format UDZO \
  "$WORK_DMG" >/dev/null

if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
  codesign --force --timestamp --sign "$APPLICATION_IDENTITY" "$WORK_DMG"
  xcrun notarytool submit "$WORK_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$WORK_DMG"
  xcrun stapler validate "$WORK_DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$WORK_DMG"
elif [[ "$TESTER_PRERELEASE" == "1" ]]; then
  echo "TESTER PRERELEASE: unsigned and unnotarized; publish only as an explicitly labelled GitHub prerelease, never as a stable update." >&2
else
  echo "LOCAL QA ONLY: built an unsigned, unnotarized DMG that must not be published." >&2
fi

cp -f "$WORK_DMG" "$DMG"

if [[ "$ALLOW_UNSIGNED_LOCAL" == "1" ]]; then
  FIREFOX_ASSET="$DIST/Intent-Firefox-Extension.zip"
  FIREFOX_SOURCE="$ROOT/dist/firefox/intent_browser_guard-${FIREFOX_VERSION}.zip"
  FIREFOX_SIGNED=false
else
  FIREFOX_ASSET="$DIST/Intent-Firefox-Extension.xpi"
  FIREFOX_SOURCE="$WORK/verified-firefox.xpi"
  [[ -n "$FIREFOX_SOURCE" ]] || {
    echo "Release refused: Mozilla did not return a signed Firefox extension." >&2
    exit 6
  }
  FIREFOX_SIGNED=true
fi
cp -f "$FIREFOX_SOURCE" "$FIREFOX_ASSET"
cp -f "$ROOT/dist/chrome/intent-browser-guard-chrome-${CHROME_VERSION}.zip" "$DIST/Intent-Chrome-Extension.zip"

DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
FIREFOX_SHA256="$(shasum -a 256 "$FIREFOX_ASSET" | awk '{print $1}')"
CHROME_SHA256="$(shasum -a 256 "$DIST/Intent-Chrome-Extension.zip" | awk '{print $1}')"
TEAM_ID=""
NOTARIZED=false
ASSET_URL=""
if [[ "$ALLOW_UNSIGNED_LOCAL" != "1" ]]; then
  TEAM_ID="$(codesign -dv --verbose=4 "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')"
  NOTARIZED=true
  ASSET_URL="https://github.com/logx8x-ui/intent-cli/releases/download/launch-${VERSION}/Intent.dmg"
fi

cat > "$DIST/release-manifest.json" <<JSON
{
  "distribution_ready": false,
  "installer_format": "pkg",
  "version": "${VERSION}",
  "build": "${BUILD_NUMBER}",
  "source_commit": "${SOURCE_COMMIT}",
  "source_dirty": ${SOURCE_DIRTY},
  "source_fingerprint": "${SOURCE_FINGERPRINT}",
  "repository": "logx8x-ui/intent-cli",
  "tag": "launch-${VERSION}",
  "channel": "${BUILD_CHANNEL}",
  "website_adder_enabled": false,
  "automatic_update_checks_enabled": false,
  "asset_url": "${ASSET_URL}",
  "sha256": "${DMG_SHA256}",
  "minimum_macos": "${MINIMUM_MACOS}",
  "architectures": ${ARCHITECTURES},
  "team_id": "${TEAM_ID}",
  "notarized": ${NOTARIZED},
  "extension_version": "${CHROME_VERSION}",
  "chrome_web_store_version": "${PUBLISHED_CHROME_VERSION}",
  "chrome_web_store_approved": ${CHROME_APPROVED},
  "chrome_store_url": "${CHROME_STORE_URL}",
  "firefox_extension_version": "${FIREFOX_VERSION}",
  "firefox_extension_asset": "$(basename "$FIREFOX_ASSET")",
  "firefox_extension_sha256": "${FIREFOX_SHA256}",
  "firefox_extension_signed": ${FIREFOX_SIGNED},
  "chrome_extension_version": "${CHROME_VERSION}",
  "chrome_extension_asset": "Intent-Chrome-Extension.zip",
  "chrome_extension_sha256": "${CHROME_SHA256}"
}
JSON

/usr/bin/python3 - "$DIST/release-manifest.json" <<'INSTALLERS'
import hashlib, json, pathlib, sys
path=pathlib.Path(sys.argv[1])
manifest=json.loads(path.read_text())
manifest['installers']={}
for choice,label in [('firefox','Firefox'),('chrome','Chrome'),('both','Both')]:
    asset=path.parent/f'Intent-{label}.pkg'
    manifest['installers'][choice]={
        'asset':asset.name, 'browser_choice':choice, 'size_bytes':asset.stat().st_size,
        'sha256':hashlib.sha256(asset.read_bytes()).hexdigest()}
path.write_text(json.dumps(manifest, indent=2)+'\n')
INSTALLERS

[[ "$(cd "$ROOT" && node -e 'console.log(require("./scripts/change-impact.cjs").sourceFingerprint(process.cwd()))')" == "$SOURCE_FINGERPRINT" ]] || {
  echo 'Source changed during packaging. This candidate must not be distributed.' >&2
  exit 7
}

printf '%s\n' \
  "$DIST/Intent-Firefox.pkg" \
  "$DIST/Intent-Chrome.pkg" \
  "$DIST/Intent-Both.pkg" \
  "$DMG" \
  "$FIREFOX_ASSET" \
  "$DIST/Intent-Chrome-Extension.zip" \
  "$DIST/release-manifest.json"
