#!/usr/bin/env bash
set -euo pipefail

# Only this signed system installation is owned here. Per-user development
# channels, legacy agents, browser profiles and all saved data are untouched.
if [[ $# -gt 0 && "${1:-}" != --system-remove ]]; then
  echo 'Usage: ./uninstall.sh' >&2
  echo 'Uninstall preserves all intentions and settings; data deletion is not part of this command.' >&2
  exit 2
fi
if [[ "${1:-}" == --system-remove && ( $# -ne 1 || "$EUID" != 0 ) ]]; then
  echo 'The system removal phase requires macOS administrator authorization.' >&2
  exit 2
fi
APP='/Applications/Intent.app'
SUPPORT='/Library/Application Support/Intent'
EXPECTED_HOST="$SUPPORT/IntentNativeHost"
EXPECTED_TEAM='Y3ZGWT477T'

refuse() { echo "Intent uninstall stopped: $1 No files have been removed." >&2; exit 1; }
# Refusal does not interrupt an enforcement engine or a native-host connection.
for process in IntentApp Intent IntentNativeHost; do
  if pgrep -x "$process" >/dev/null 2>&1; then
    if [[ "$process" == IntentNativeHost ]]; then
      refuse 'quit Firefox and Chrome to disconnect Browser Guard, then retry.'
    fi
    refuse 'finish your intention and close Intent and Test Intent before uninstalling.'
  else
    result=$?
    [[ "$result" == 1 ]] || refuse 'could not inspect running processes.'
  fi
done
for directory in '/Applications' "$APP" '/Library' '/Library/Application Support' "$SUPPORT" \
  '/Library/Application Support/Mozilla' '/Library/Application Support/Mozilla/NativeMessagingHosts' \
  '/Library/Google' '/Library/Google/Chrome' '/Library/Google/Chrome/NativeMessagingHosts'; do
  [[ ! -L "$directory" ]] || refuse 'an installation destination is a symbolic link.'
done
[[ ! -e '/Library/LaunchAgents/dev.loganmondi.intent.plist' && ! -L '/Library/LaunchAgents/dev.loganmondi.intent.plist' ]] || \
  refuse 'a legacy launch agent requires separate migration.'

signed_by_intent() {
  /usr/bin/codesign --verify --strict "$1" >/dev/null 2>&1 &&
    /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/grep -Fx "TeamIdentifier=$EXPECTED_TEAM" >/dev/null
}
if [[ -e "$APP" ]]; then
  bundle=$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null) || refuse 'could not verify the application.'
  [[ "$bundle" == dev.loganmondi.intent ]] || refuse 'the application belongs to another channel.'
  signed_by_intent "$APP" || refuse 'the application has a different or invalid signing identity.'
fi
for binary in "$SUPPORT/Intent" "$EXPECTED_HOST"; do
  [[ ! -L "$binary" ]] || refuse 'an installed executable is a symbolic link.'
  if [[ -e "$binary" ]]; then
    signed_by_intent "$binary" || refuse 'an installed executable is not signed by Intent.'
  fi
done
MANIFESTS=(
  '/Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json'
  '/Library/Google/Chrome/NativeMessagingHosts/intent_native_host.json'
)
for manifest in "${MANIFESTS[@]}"; do
  [[ ! -L "$manifest" ]] || refuse 'a browser registration is a symbolic link.'
  if [[ -e "$manifest" ]]; then
    host=$(/usr/bin/plutil -extract path raw -o - "$manifest" 2>/dev/null) || refuse 'a browser registration is invalid.'
    name=$(/usr/bin/plutil -extract name raw -o - "$manifest" 2>/dev/null) || refuse 'a browser registration is invalid.'
    [[ "$host" == "$EXPECTED_HOST" && "$name" == intent_native_host && -f "$EXPECTED_HOST" ]] || \
      refuse 'a browser registration belongs to a different installation.'
  fi
done

if [[ "${1:-}" != --system-remove ]]; then
  # Re-run every ownership/process check after elevation. Paths are passed as
  # argv, not interpolated into AppleScript or a shell command.
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  /usr/bin/osascript \
    -e 'on run argv' \
    -e 'do shell script "/bin/bash " & quoted form of (item 1 of argv) & " --system-remove" with administrator privileges' \
    -e 'end run' "$SCRIPT_PATH"
  echo 'Intent was removed. Your saved intentions, settings and browser profiles are preserved.'
  exit 0
fi

# No broad directory removal: unknown support files and all per-user data stay.
/bin/rm -rf "$APP"
for manifest in "${MANIFESTS[@]}"; do
  [[ ! -e "$manifest" ]] || /bin/rm -f "$manifest"
done
/bin/rm -f "$SUPPORT/Intent" "$EXPECTED_HOST"
if [[ -d "$SUPPORT" ]]; then /bin/rmdir "$SUPPORT" 2>/dev/null || true; fi
/usr/sbin/pkgutil --forget dev.loganmondi.intent >/dev/null 2>&1 || true
[[ ! -e "$APP" && ! -e "$EXPECTED_HOST" ]] || { echo 'Intent uninstall verification failed.' >&2; exit 1; }
