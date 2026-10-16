#!/usr/bin/env bash
# Real main/worker Carbon regression; reads rcmd only, never sends input or
# changes its configuration, and never installs or starts an intention.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-rcmd-platform.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library \
  "$ROOT/Sources/IntentLock/NativeProcessLaunchDate.swift" \
  "$ROOT/Sources/IntentLock/RcmdKeyboardLayoutCache.swift" \
  "$ROOT/Sources/IntentLock/RcmdInputPolicy.swift" \
  "$ROOT/Sources/IntentLock/RcmdCompatibilityMonitor.swift" \
  "$ROOT/scripts/test-rcmd-platform.swift" -o "$WORK/rcmd-platform-spec"
"$WORK/rcmd-platform-spec"
