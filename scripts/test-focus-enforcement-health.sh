#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-enforcement-spec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library "$ROOT/Sources/IntentLock/FocusEnforcementHealth.swift" \
  "$ROOT/Sources/IntentLock/FocusInputRecoveryQueue.swift" \
  "$ROOT/Sources/IntentLock/FocusSelectedWindowRecoveryPolicy.swift" \
  "$ROOT/Sources/IntentCore/DeferredSessionActionGate.swift" \
  "$ROOT/scripts/test-focus-enforcement-health.swift" -o "$WORK/enforcement-spec"
"$WORK/enforcement-spec"
