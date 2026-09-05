#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/chrome-extension"
DIST="$ROOT/dist/chrome"
VERSION="$(node -p "require('$SOURCE/manifest.json').version")"
MODE="${1:-development}"

case "$MODE" in
  development)
    STAGE="$DIST/intent-browser-guard-chrome"
    ARCHIVE="$DIST/intent-browser-guard-chrome-${VERSION}.zip"
    ;;
  --web-store)
    STAGE="$DIST/intent-browser-guard-chrome-web-store"
    ARCHIVE="$DIST/intent-browser-guard-chrome-web-store-${VERSION}.zip"
    ;;
  *)
    echo "Usage: $0 [--web-store]" >&2
    exit 2
    ;;
esac

rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE"
cp -R "$SOURCE/." "$STAGE/"

if [[ "$MODE" == "--web-store" ]]; then
  node - "$STAGE/manifest.json" <<'NODE'
const fs = require("node:fs");
const manifestPath = process.argv[2];
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
delete manifest.key;
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
fi

cd "$STAGE"
zip -qr "$ARCHIVE" .
echo "$ARCHIVE"
