#!/bin/bash
set -euo pipefail

# These constants are pinned to the payload by the release builder/verifier.
RELEASE_ARCHITECTURE=arm64
MINIMUM_MACOS_MAJOR=13
if [[ "${3:-/}" != / ]]; then
  echo 'Install Intent on your current startup disk.' >&2
  exit 1
fi
OS_VERSION=$(/usr/bin/sw_vers -productVersion) || {
  echo 'Installation stopped: macOS compatibility could not be checked.' >&2
  exit 1
}
if [[ ! "$OS_VERSION" =~ ^[0-9]{1,3}\.[0-9]{1,3}(\.[0-9]{1,3})?$ ]]; then
  echo 'Installation stopped: macOS compatibility could not be checked.' >&2
  exit 1
fi
OS_MAJOR="${OS_VERSION%%.*}"
if (( 10#$OS_MAJOR < MINIMUM_MACOS_MAJOR )); then
  echo "Intent requires macOS ${MINIMUM_MACOS_MAJOR} or later. Your installation has not changed." >&2
  exit 1
fi
case "$RELEASE_ARCHITECTURE" in
  arm64)
    # uname reports x86_64 when Installer runs under Rosetta; hardware support
    # still identifies Apple Silicon without rejecting that supported Mac.
    ARM64_SUPPORTED=$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null) || ARM64_SUPPORTED=unknown
    if [[ "$ARM64_SUPPORTED" != 1 ]]; then
      echo 'This Intent installer requires an Apple Silicon Mac. Your installation has not changed.' >&2
      exit 1
    fi
    ;;
  universal)
    MACHINE=$(/usr/bin/uname -m) || MACHINE=unknown
    case "$MACHINE" in arm64|x86_64) ;; *)
      echo 'Installation stopped: this Mac is not supported by Intent.' >&2
      exit 1 ;;
    esac
    ;;
  *) echo 'Installation stopped: the package architecture is invalid.' >&2; exit 1 ;;
esac

# Never terminate either channel: closing Intent owns visibility restoration.
# A conservative refusal is safer than replacing a running enforcement engine.
for process in IntentApp Intent; do
  if pgrep -x "$process" >/dev/null 2>&1; then
    echo "Close Intent and Test Intent before installing this update. Your current intention has not been interrupted." >&2
    exit 1
  else
    result=$?
    if [[ "$result" != 1 ]]; then
      echo "Could not check whether Intent is running; installation has been stopped safely." >&2
      exit 1
    fi
  fi
done

EXPECTED_HOST='/Library/Application Support/Intent/IntentNativeHost'
for directory in \
  '/Applications' \
  '/Applications/Intent.app' \
  '/Library' \
  '/Library/Application Support' \
  '/Library/Application Support/Intent' \
  '/Library/Application Support/Mozilla' \
  '/Library/Application Support/Mozilla/NativeMessagingHosts' \
  '/Library/Google' \
  '/Library/Google/Chrome' \
  '/Library/Google/Chrome/NativeMessagingHosts'; do
  if [[ -L "$directory" ]]; then
    echo "Installation stopped: an Intent destination is a symbolic link." >&2
    exit 1
  fi
done
if [[ -e '/Applications/Intent.app' ]]; then
  bundle=$(plutil -extract CFBundleIdentifier raw -o - '/Applications/Intent.app/Contents/Info.plist' 2>/dev/null) || {
    echo "Installation stopped: the existing app could not be verified." >&2
    exit 1
  }
  if [[ "$bundle" != dev.loganmondi.intent ]]; then
    echo "Installation stopped: this app destination belongs to a different application." >&2
    exit 1
  fi
fi
for manifest in \
  '/Library/Application Support/Mozilla/NativeMessagingHosts/intent_native_host.json' \
  '/Library/Google/Chrome/NativeMessagingHosts/intent_native_host.json'; do
  if [[ -L "$manifest" ]]; then
    echo "Installation stopped: the browser host registration is a symbolic link." >&2
    exit 1
  fi
  if [[ -e "$manifest" ]]; then
    host=$(plutil -extract path raw -o - "$manifest" 2>/dev/null) || {
      echo "Installation stopped: the existing browser host registration could not be verified." >&2
      exit 1
    }
    if [[ "$host" != "$EXPECTED_HOST" ]]; then
      echo "Installation stopped: the browser host registration belongs to a different installation." >&2
      exit 1
    fi
  fi
done

# Older launch agents can restart a binary while Installer replaces it. Do not
# delete a user's agent or disable it silently; require its separate migration.
if [[ -e '/Library/LaunchAgents/dev.loganmondi.intent.plist' || -L '/Library/LaunchAgents/dev.loganmondi.intent.plist' ]]; then
  echo "Installation stopped: a legacy Intent launch agent needs migration before updating." >&2
  exit 1
fi
