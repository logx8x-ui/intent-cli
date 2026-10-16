#!/usr/bin/env bash
# Read-only observer: never creates an input tap or changes apps/settings.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-rcmd-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library \
  "$ROOT/Sources/IntentLock/NativeProcessLaunchDate.swift" \
  "$ROOT/Sources/IntentLock/RcmdKeyboardLayoutCache.swift" \
  "$ROOT/Sources/IntentLock/RcmdCompatibilityDiagnostics.swift" \
  "$ROOT/Sources/IntentLock/RcmdInputPolicy.swift" \
  "$ROOT/Sources/IntentLock/RcmdCompatibilityMonitor.swift" \
  "$ROOT/scripts/probe-rcmd-compatibility.swift" -o "$WORK/rcmd-probe"
"$WORK/rcmd-probe" "${1:-90}"
