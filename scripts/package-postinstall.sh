#!/bin/bash
set -euo pipefail

# Replaced only with a validated enum while building each signed package.
SETUP_BROWSER_CHOICE=both
case "$SETUP_BROWSER_CHOICE" in firefox|chrome|both) ;; *) exit 1 ;; esac
chmod +x '/Applications/Intent.app/Contents/MacOS/IntentApp'
chmod +x '/Library/Application Support/Intent/IntentNativeHost'
# Durable, non-secret fallback if no one is logged in or LaunchServices cannot
# open the app yet. Onboarding consumes it only once, for this exact app build.
APP_BUILD=$(/usr/bin/plutil -extract CFBundleVersion raw -o - '/Applications/Intent.app/Contents/Info.plist')
[[ "$APP_BUILD" =~ ^[0-9]+$ ]] || exit 1
RECEIPT='/Library/Application Support/Intent/onboarding-browser-choice.json'
TEMP_RECEIPT="$(mktemp '/Library/Application Support/Intent/.onboarding-browser-choice.XXXXXX')"
trap '[[ ! -f "$TEMP_RECEIPT" ]] || rm -f "$TEMP_RECEIPT"' EXIT
printf '{"version":1,"browsers":"%s","app_build":"%s"}\n' "$SETUP_BROWSER_CHOICE" "$APP_BUILD" > "$TEMP_RECEIPT"
/usr/sbin/chown root:wheel "$TEMP_RECEIPT"
chmod 0644 "$TEMP_RECEIPT"
mv -f "$TEMP_RECEIPT" "$RECEIPT"
CONSOLE_USER="$(stat -f '%Su' /dev/console)"
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != root && "$CONSOLE_USER" != loginwindow ]]; then
  USER_ID="$(id -u "$CONSOLE_USER")"
  LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f '/Applications/Intent.app' >/dev/null 2>&1 || true
  fi
  # The installed executable parses this single allowlisted enum and persists
  # it in the user's onboarding state; the root installer never edits profiles.
  launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" /usr/bin/open \
    -n '/Applications/Intent.app' --args "--setup-browsers=$SETUP_BROWSER_CHOICE" || {
      echo 'Intent is installed. Open Intent from Applications to continue setup.' >&2
    }
fi
exit 0
