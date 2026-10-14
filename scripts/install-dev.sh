#!/usr/bin/env bash
set -euo pipefail

# Explicit local source installs. Neither branch creates a public release.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/build-jobs.sh"
CHANNEL=development
PRINT_PLAN=0
for argument in "$@"; do
  case "$argument" in
    --launch-local) CHANNEL=launch ;;
    --print-plan) PRINT_PLAN=1 ;;
    *) echo "Usage: scripts/install-dev.sh [--launch-local] [--print-plan]" >&2; exit 64 ;;
  esac
done
if [[ "$CHANNEL" == development ]]; then
  APP_NAME='Test Intent'
  BUNDLE_ID='dev.loganmondi.intent.test'
  AUTH_SCHEME='intent-test'
  DATA_NAME='.intent-test'
  BUILD="$ROOT/.build-development"
  DEVELOPMENT_PLIST='<true/>'
  CLI_NAME='test-intent'
  CLI_APP_NAME='TestIntentApp'
  LAUNCHER_NAME='test-intent-app'
  SWIFT_FLAGS=(-Xswiftc -D -Xswiftc INTENT_DEVELOPMENT)
else
  APP_NAME='Intent'
  BUNDLE_ID='dev.loganmondi.intent'
  AUTH_SCHEME='intent'
  DATA_NAME='.intent'
  BUILD="$ROOT/.build-launch"
  DEVELOPMENT_PLIST='<false/>'
  CLI_NAME='intent'
  CLI_APP_NAME='IntentApp'
  LAUNCHER_NAME='intent-app'
  SWIFT_FLAGS=()
fi
APP_DIR="${HOME}/${DATA_NAME}/bin"
APP_BUNDLE="${HOME}/Applications/${APP_NAME}.app"
BIN_DIR="${HOME}/.local/bin"

# A side-effect-free plan is also used by installer regression fixtures.
if [[ "$PRINT_PLAN" == 1 ]]; then
  /usr/bin/python3 - "$CHANNEL" "$APP_NAME" "$BUNDLE_ID" "$AUTH_SCHEME" "$DATA_NAME" "$BUILD" "$APP_BUNDLE" "$APP_DIR" "$CLI_NAME" <<'PY'
import json,sys
keys=('channel','app_name','bundle_identifier','auth_scheme','data_directory_name','build_path','app_bundle','binary_directory','cli_name')
print(json.dumps(dict(zip(keys,sys.argv[1:]))))
PY
  exit 0
fi

require_closed_engines() {
  # The shipped CLI can enforce app-only restrictions without a durable lease.
  # Refuse it as well as either app; installation never terminates those engines.
  /usr/bin/python3 "$ROOT/scripts/check-local-channel-idle.py" "$HOME" --require-closed
}
require_closed_engines

GOOGLE_CLIENT_SECRET="${INTENT_GOOGLE_CLIENT_SECRET:-}"
if [[ -z "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_CLIENT_SECRET="$(security find-generic-password -s 'dev.loganmondi.intent.build' -a 'google-oauth-client-secret' -w 2>/dev/null || true)"
fi
cd "$ROOT"
for product in Intent IntentApp IntentNativeHost; do
  swift build -c release --jobs "$INTENT_BUILD_JOBS" --scratch-path "$BUILD" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --product "$product"
done
BUILD_BIN="$(swift build -c release --jobs "$INTENT_BUILD_JOBS" --scratch-path "$BUILD" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} --show-bin-path)"
[[ "$("$BUILD_BIN/IntentApp" --print-build-channel)" == "$CHANNEL" ]] || {
  echo 'Refusing an executable compiled for another channel.' >&2; exit 4;
}
require_closed_engines

commit_installation() {
# The transaction wrapper holds engine.lock throughout this function. It refuses
# either running app, including selection/preparation, without terminating it.

# A running pre-lease helper still executes its old memory-mapped code after
# atomic file replacement. Retire this idle target only, before replacing it;
# the owner startup hook then reconnects browsers through the selected channel.
/usr/bin/python3 "$ROOT/scripts/retire-local-channel-hosts.py" \
  "$APP_BUNDLE/Contents/Helpers/IntentNativeHost" "$APP_DIR/IntentNativeHost"

atomic_install_executable() {
  local source="$1" destination="$2" temporary="${2}.new.$$"
  cp "$source" "$temporary"
  chmod +x "$temporary"
  mv -f "$temporary" "$destination"
}
mkdir -p "$BIN_DIR" "$APP_DIR" "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
chmod 700 "${HOME}/${DATA_NAME}"
for product in Intent IntentApp IntentNativeHost; do
  atomic_install_executable "$BUILD_BIN/$product" "$APP_DIR/$product"
done
atomic_install_executable "$BUILD_BIN/IntentApp" "$APP_BUNDLE/Contents/MacOS/IntentApp"
/usr/bin/ditto "$BUILD_BIN/Intent_IntentApp.bundle" "$APP_BUNDLE/Contents/Resources/Intent_IntentApp.bundle"
"$ROOT/scripts/configure-supabase-bundle.sh" "$APP_BUNDLE/Contents/Resources/Intent_IntentApp.bundle" 0
cp "$ROOT/Assets/Intent.icns" "$APP_BUNDLE/Contents/Resources/Intent.icns"
if [[ -n "$GOOGLE_CLIENT_SECRET" ]]; then
  GOOGLE_CONFIG="$APP_BUNDLE/Contents/Resources/GoogleCalendarConfig.plist"
  cp "$ROOT/Sources/IntentApp/Resources/GoogleCalendarConfig.plist" "$GOOGLE_CONFIG"
  /usr/libexec/PlistBuddy -c 'Delete :CLIENT_SECRET' "$GOOGLE_CONFIG" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CLIENT_SECRET string $GOOGLE_CLIENT_SECRET" "$GOOGLE_CONFIG"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>IntentApp</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
<key>CFBundleName</key><string>${APP_NAME}</string>
<key>CFBundleDisplayName</key><string>${APP_NAME}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>Intent</string>
<key>IntentBuildChannel</key><string>${CHANNEL}</string>
<key>IntentDevelopmentBuild</key>${DEVELOPMENT_PLIST}
<key>IntentLocalQABuild</key><true/>
<key>IntentChromePublishedGuardVersion</key><string></string>
<key>CFBundleShortVersionString</key><string>0.9.3-local</string>
<key>CFBundleVersion</key><string>202610110001</string>
<key>CFBundleURLTypes</key><array><dict>
<key>CFBundleURLName</key><string>${BUNDLE_ID}.auth</string>
<key>CFBundleURLSchemes</key><array><string>${AUTH_SCHEME}</string></array>
</dict></array>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSMicrophoneUsageDescription</key><string>${APP_NAME} uses the microphone only while you speak your purpose in Purpose Mode.</string>
<key>NSSpeechRecognitionUsageDescription</key><string>${APP_NAME} turns your spoken purpose into text so it can start the right focused session.</string>
<key>NSCalendarsUsageDescription</key><string>${APP_NAME} can show calendars when you choose Connect.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>${APP_NAME} can show calendars when you choose Connect.</string>
<key>NSRemindersUsageDescription</key><string>${APP_NAME} can show Reminders when you enable it.</string>
<key>NSRemindersFullAccessUsageDescription</key><string>${APP_NAME} can show Reminders when you enable it.</string>
</dict></plist>
PLIST
"$ROOT/scripts/embed-update-components.sh" "$APP_BUNDLE" "$BUILD"
codesign --force --sign - "$APP_BUNDLE/Contents/Helpers/IntentNativeHost"
codesign --force --sign - --identifier "$BUNDLE_ID" \
  --requirements "=designated => identifier \"$BUNDLE_ID\"" "$APP_BUNDLE" >/dev/null
ln -sf "$APP_DIR/Intent" "$BIN_DIR/$CLI_NAME"
ln -sf "$APP_DIR/IntentApp" "$BIN_DIR/$CLI_APP_NAME"
cat > "$BIN_DIR/$LAUNCHER_NAME" <<LAUNCHER
#!/usr/bin/env bash
open "$APP_BUNDLE"
LAUNCHER
chmod +x "$BIN_DIR/$LAUNCHER_NAME"
if [[ "$CHANNEL" == launch ]]; then ln -sf "$APP_DIR/Intent" "$BIN_DIR/Intent"; fi
if [[ -w /opt/homebrew/bin ]]; then
  ln -sf "$APP_DIR/Intent" "/opt/homebrew/bin/$CLI_NAME"
  ln -sf "$APP_DIR/IntentApp" "/opt/homebrew/bin/$CLI_APP_NAME"
  ln -sf "$BIN_DIR/$LAUNCHER_NAME" "/opt/homebrew/bin/$LAUNCHER_NAME"
fi
}

export ROOT CHANNEL APP_NAME BUNDLE_ID AUTH_SCHEME DATA_NAME BUILD APP_DIR APP_BUNDLE
export BIN_DIR BUILD_BIN DEVELOPMENT_PLIST CLI_NAME CLI_APP_NAME LAUNCHER_NAME GOOGLE_CLIENT_SECRET
export -f commit_installation
/usr/bin/python3 "$ROOT/scripts/local-channel-install-transaction.py" "$HOME" -- \
  "$BASH" -c 'set -euo pipefail; commit_installation'
# Opening is deliberately outside the lease; the installed app owns its normal
# channel handoff and native-host registration only after commit finishes.
mdimport "$APP_BUNDLE" 2>/dev/null || true
printf 'Installed %s to %s (%s, local QA only).\n' "$APP_NAME" "$APP_BUNDLE" "$CHANNEL"
if [[ "${INTENT_LOCAL_INSTALL_NO_OPEN:-0}" == 1 ]]; then exit 0; fi
open "$APP_BUNDLE"
echo 'The app acquires engine ownership before registering Browser Guard. Only one channel controls the Mac at a time.'
/usr/bin/python3 - "$APP_BUNDLE/Contents/MacOS/IntentApp" "$APP_NAME" <<'PY'
import subprocess,sys,time
expected,name=sys.argv[1:]
for _ in range(50):
    commands=subprocess.check_output(['/bin/ps','-axo','command='],text=True).splitlines()
    if any(command==expected or command.startswith(expected+' ') for command in commands):
        print(f'{name} is running in the menu bar.')
        break
    time.sleep(.1)
else: sys.exit(f'{name} was installed but did not stay running. Check engine ownership and macOS permissions.')
PY
