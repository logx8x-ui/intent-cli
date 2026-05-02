#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
APP_DIR="${HOME}/.intent/bin"

cd "$ROOT"
swift build -c release --product Intent

mkdir -p "$BIN_DIR"
mkdir -p "$APP_DIR"
cp "$ROOT/.build/release/Intent" "$APP_DIR/Intent"
chmod +x "$APP_DIR/Intent"

ln -sf "$APP_DIR/Intent" "$BIN_DIR/Intent"
ln -sf "$APP_DIR/Intent" "$BIN_DIR/intent"

echo "Installed Intent and intent to $BIN_DIR"

if [[ -w /opt/homebrew/bin ]]; then
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/Intent
  ln -sf "$APP_DIR/Intent" /opt/homebrew/bin/intent
  echo "Also linked Intent and intent to /opt/homebrew/bin"
elif [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "Make sure $BIN_DIR is on your PATH."
fi
