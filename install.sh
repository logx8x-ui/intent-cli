#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Intent currently supports macOS only." >&2
  exit 1
fi

RELEASE_BASE="${INTENT_RELEASE_BASE:-https://github.com/logx8x-ui/intent-cli/releases/latest/download}"
MANIFEST_URL="${INTENT_MANIFEST_URL:-$RELEASE_BASE/release-manifest.json}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/intent-install.XXXXXX")"
MANIFEST="$WORK_DIR/release-manifest.json"
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

json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

download() {
  /usr/bin/curl --fail --location --silent --show-error \
    --retry 3 --connect-timeout 15 "$1" --output "$2"
}

mkdir -p "$MOUNT_POINT"
echo "Checking the latest verified Intent release..."
if ! download "$MANIFEST_URL" "$MANIFEST"; then
  echo "Intent could not download the verified release manifest. No installation was performed." >&2
  echo "Check your connection and https://github.com/logx8x-ui/intent-cli/releases for a signed release containing release-manifest.json." >&2
  exit 2
fi

NOTARIZED="$(json_value notarized)"
TEAM_ID="$(json_value team_id)"
DMG_URL="$(json_value asset_url)"
EXPECTED_SHA256="$(json_value sha256)"
VERSION="$(json_value version)"

if [[ "$NOTARIZED" != "true" || -z "$TEAM_ID" || -z "$DMG_URL" || -z "$EXPECTED_SHA256" ]]; then
  echo "Intent refused this release because it is not signed and notarized for public installation." >&2
  exit 2
fi

echo "Downloading Intent $VERSION..."
download "$DMG_URL" "$DMG_PATH"

ACTUAL_SHA256="$(/usr/bin/shasum -a 256 "$DMG_PATH" | /usr/bin/awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "Intent refused the download because its checksum did not match the published release." >&2
  exit 3
fi

echo "Verifying Apple's security checks..."
/usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
/usr/bin/hdiutil attach "$DMG_PATH" \
  -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
MOUNTED=1

PACKAGE="$(/usr/bin/find "$MOUNT_POINT" -maxdepth 1 -type f -name '*.pkg' -print -quit)"
if [[ -z "$PACKAGE" ]]; then
  echo "The verified Intent download did not contain its installer." >&2
  exit 4
fi

SIGNATURE_OUTPUT="$(/usr/sbin/pkgutil --check-signature "$PACKAGE")"
if [[ "$SIGNATURE_OUTPUT" != *"($TEAM_ID)"* && "$SIGNATURE_OUTPUT" != *"Team Identifier: $TEAM_ID"* ]]; then
  echo "Intent refused the installer because its Apple publisher did not match the release manifest." >&2
  exit 5
fi
/usr/sbin/spctl --assess --type install --verbose=2 "$PACKAGE"

if [[ "${INTENT_INSTALL_DRY_RUN:-0}" == "1" ]]; then
  echo "Verified Intent $VERSION. No installation was performed."
  exit 0
fi

echo "macOS will ask once for permission to install Intent."
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" with administrator privileges' \
  -e 'end run' \
  "$PACKAGE"

echo "Intent $VERSION is installed and opening now."
