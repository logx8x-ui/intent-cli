#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-channel-fixtures.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library \
  "$ROOT/Sources/IntentCore/IntentBuildPolicy.swift" "$ROOT/Sources/IntentCore/IntentEnvironment.swift" \
  "$ROOT/Sources/IntentCore/IntentEngineLease.swift" "$ROOT/Sources/IntentCore/IntentChannelSeed.swift" \
  "$ROOT/scripts/test-channel-isolation.swift" -o "$WORK/channel-probe"
"$WORK/channel-probe"
node "$ROOT/scripts/test-local-channel-installer.cjs"
/usr/bin/python3 "$ROOT/scripts/test-local-channel-idle.py"
/usr/bin/python3 "$ROOT/scripts/test-local-channel-host-retirement.py"
if [[ -n "${INTENT_NATIVE_HOST_PATH:-}" && -x "$INTENT_NATIVE_HOST_PATH" ]]; then
  INTENT_CHANNEL_LEASE_PROBE_PATH="$WORK/channel-probe" node "$ROOT/scripts/test-native-channel-routing.cjs"
fi
