#!/usr/bin/env bash
set -euo pipefail

DELETE_DATA=0
if [[ "${1:-}" == "--delete-data" ]]; then
  DELETE_DATA=1
elif [[ $# -gt 0 ]]; then
  echo "Usage: $0 [--delete-data]" >&2
  exit 2
fi

APP="/Applications/Intent.app"
SUPPORT="/Library/Application Support/Intent"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

pkill -x IntentApp 2>/dev/null || true
pkill -x IntentNativeHost 2>/dev/null || true
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

ADMIN_SCRIPT='
/bin/rm -rf "/Applications/Intent.app"
/bin/rm -rf "/Library/Application Support/Intent"
/bin/rm -f "/Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json"
/bin/rm -f "/Library/Google/Chrome/NativeMessagingHosts/intent_native_host.json"
/bin/rm -f "/Library/LaunchAgents/dev.loganmondi.intent.plist"
/usr/sbin/pkgutil --forget dev.loganmondi.intent >/dev/null 2>&1 || true
'
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'do shell script (item 1 of argv) with administrator privileges' \
  -e 'end run' \
  "$ADMIN_SCRIPT"

/bin/rm -f "$HOME/Library/LaunchAgents/dev.loganmondi.intent.plist"
/bin/rm -f "$HOME/Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json"
/bin/rm -f "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/intent_native_host.json"
/bin/rm -rf "$HOME/.intent/bin" "$HOME/.intent/Intent.app"

if [[ "$DELETE_DATA" == "1" ]]; then
  /bin/rm -rf "$HOME/.intent"
  /usr/bin/defaults delete dev.loganmondi.intent 2>/dev/null || true
  echo "Intent and its local data were removed."
else
  echo "Intent was removed. Your intentions and settings remain in $HOME/.intent."
  echo "Run '$0 --delete-data' to remove those too."
fi

if [[ -e "$APP" || -e "$SUPPORT" ]]; then
  echo "Intent uninstall verification failed." >&2
  exit 1
fi
