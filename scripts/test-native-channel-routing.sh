#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
host_path="$(swift build -c release --show-bin-path)/IntentNativeHost"
[[ -x "$host_path" ]] || { echo 'Build the release native host before its channel routing check.' >&2; exit 2; }
INTENT_NATIVE_HOST_PATH="$host_path" bash scripts/test-channel-isolation.sh
