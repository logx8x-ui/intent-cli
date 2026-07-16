#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/chrome-extension"
DIST="$ROOT/dist/chrome"
STAGE="$DIST/intent-browser-guard-chrome"
ARCHIVE="$DIST/intent-browser-guard-chrome-0.1.0.zip"

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE"
cp -R "$SOURCE/." "$STAGE/"

cd "$STAGE"
zip -qr "$ARCHIVE" .
echo "$ARCHIVE"
