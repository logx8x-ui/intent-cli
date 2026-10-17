#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-desktop-session-spec.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
swiftc -parse-as-library -emit-module -emit-library -module-name IntentCore \
  "$ROOT"/Sources/IntentCore/*.swift -emit-module-path "$WORK/IntentCore.swiftmodule" -o "$WORK/libIntentCore.dylib"
swiftc -parse-as-library -I "$WORK" -L "$WORK" -lIntentCore -Xlinker -rpath -Xlinker "$WORK" \
  "$ROOT/Sources/IntentLock/DesktopSessionAvailability.swift" \
  "$ROOT/Sources/IntentCoreSpec/DesktopSessionCoverageSpecs.swift" \
  "$ROOT/scripts/test-desktop-session-coverage.swift" -o "$WORK/desktop-session-spec"
"$WORK/desktop-session-spec"
