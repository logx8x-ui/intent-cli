#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="${1:-$ROOT/dist/release/Intent.dmg}"
MANIFEST="${2:-$ROOT/dist/release/release-manifest.json}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-verify.XXXXXX")"
MOUNT="$WORK/mounted"
MOUNTED=0

cleanup() {
  [[ "$MOUNTED" == "1" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

[[ -f "$DMG" ]] || { echo "Missing signed release: $DMG" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "Missing release manifest: $MANIFEST" >&2; exit 1; }
! rg -n 'allowedTouchTypes' "$ROOT/Sources/IntentApp/IntentGraphView.swift" >/dev/null || {
  echo "The macOS 15 gesture-crash selector has returned." >&2
  exit 2
}

NOTARIZED="$(plutil -extract notarized raw -o - "$MANIFEST")"
TEAM_ID="$(plutil -extract team_id raw -o - "$MANIFEST")"
EXPECTED_SHA="$(plutil -extract sha256 raw -o - "$MANIFEST")"
FIREFOX_ASSET_NAME="$(plutil -extract firefox_extension_asset raw -o - "$MANIFEST")"
FIREFOX_EXPECTED_SHA="$(plutil -extract firefox_extension_sha256 raw -o - "$MANIFEST")"
FIREFOX_SIGNED="$(plutil -extract firefox_extension_signed raw -o - "$MANIFEST")"
CHROME_ASSET_NAME="$(plutil -extract chrome_extension_asset raw -o - "$MANIFEST")"
CHROME_EXPECTED_SHA="$(plutil -extract chrome_extension_sha256 raw -o - "$MANIFEST")"
[[ "$NOTARIZED" == "true" && -n "$TEAM_ID" ]] || {
  echo "Manifest does not describe a notarized Developer ID release." >&2
  exit 3
}
[[ "$(shasum -a 256 "$DMG" | awk '{print $1}')" == "$EXPECTED_SHA" ]] || {
  echo "DMG checksum does not match release-manifest.json." >&2
  exit 4
}
FIREFOX_ASSET="$ROOT/dist/release/$FIREFOX_ASSET_NAME"
CHROME_ASSET="$ROOT/dist/release/$CHROME_ASSET_NAME"
[[ "$FIREFOX_SIGNED" == "true" && "$FIREFOX_ASSET_NAME" == *.xpi && -f "$FIREFOX_ASSET" ]] || {
  echo "Release does not contain a signed Firefox Browser Guard." >&2
  exit 9
}
[[ -f "$CHROME_ASSET" ]] || { echo "Release does not contain Chrome Browser Guard." >&2; exit 10; }
[[ "$(shasum -a 256 "$FIREFOX_ASSET" | awk '{print $1}')" == "$FIREFOX_EXPECTED_SHA" ]] || {
  echo "Firefox Browser Guard checksum does not match release-manifest.json." >&2
  exit 11
}
[[ "$(shasum -a 256 "$CHROME_ASSET" | awk '{print $1}')" == "$CHROME_EXPECTED_SHA" ]] || {
  echo "Chrome Browser Guard checksum does not match release-manifest.json." >&2
  exit 12
}
unzip -tq "$FIREFOX_ASSET" >/dev/null
unzip -l "$FIREFOX_ASSET" | grep -F 'META-INF/mozilla.rsa' >/dev/null || {
  echo "Firefox Browser Guard is missing its Mozilla signature." >&2
  exit 13
}
unzip -tq "$CHROME_ASSET" >/dev/null

xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
mkdir -p "$MOUNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
MOUNTED=1
PKG="$(find "$MOUNT" -maxdepth 1 -type f -name '*.pkg' -print -quit)"
[[ -n "$PKG" ]] || { echo "DMG contains no installer package." >&2; exit 5; }
SIGNATURE_OUTPUT="$(pkgutil --check-signature "$PKG")"
[[ "$SIGNATURE_OUTPUT" == *"($TEAM_ID)"* || "$SIGNATURE_OUTPUT" == *"Team Identifier: $TEAM_ID"* ]] || {
  echo "Installer Team ID does not match release-manifest.json." >&2
  exit 6
}
spctl --assess --type install --verbose=2 "$PKG"

EXPANDED="$WORK/expanded"
pkgutil --expand-full "$PKG" "$EXPANDED"
APP="$(find "$EXPANDED" -path '*/Applications/Intent.app' -type d -print -quit)"
[[ -n "$APP" ]] || { echo "Package does not install /Applications/Intent.app." >&2; exit 7; }
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=4 "$APP" 2>&1 | grep -F "TeamIdentifier=$TEAM_ID"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/IntentApp")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || {
  echo "IntentApp is not universal: $ARCHS" >&2
  exit 8
}

echo "Intent release verification passed."
