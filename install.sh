#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Intent currently supports macOS only." >&2
  exit 1
fi

DMG_URL="${INTENT_DMG_URL:-https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent.dmg}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/intent-install.XXXXXX")"
DMG_PATH="$WORK_DIR/Intent.dmg"
MOUNT_POINT="$WORK_DIR/mounted"
MOUNTED=0

cleanup() {
  if [[ "$MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

mkdir -p "$MOUNT_POINT"
echo "Downloading the latest Intent release..."
/usr/bin/curl --fail --location --silent --show-error \
  --retry 3 --connect-timeout 15 \
  "$DMG_URL" \
  --output "$DMG_PATH"

echo "Checking the download..."
/usr/bin/hdiutil attach "$DMG_PATH" \
  -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1

PACKAGE="$(/usr/bin/find "$MOUNT_POINT" -maxdepth 1 -type f -name '*.pkg' -print -quit)"
if [[ -z "$PACKAGE" ]]; then
  echo "The latest Intent download did not contain its installer." >&2
  exit 1
fi

if [[ "${INTENT_INSTALL_DRY_RUN:-0}" == "1" ]]; then
  echo "Verified the latest Intent installer: $PACKAGE"
  exit 0
fi

echo "macOS will ask once for permission to install Intent."
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" with administrator privileges' \
  -e 'end run' \
  "$PACKAGE"

echo "Intent is installed and opening now."
