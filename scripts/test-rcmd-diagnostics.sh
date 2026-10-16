#!/usr/bin/env bash
# Isolated policy/spec executable only; no intention, event tap or daily ledger.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/intent-rcmd-diagnostics.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
sed '/^import IntentLock$/d' "$ROOT/Sources/IntentCoreSpec/RcmdCompatibilitySpecs.swift" > "$WORK/RcmdCompatibilitySpecs.swift"
cat > "$WORK/Runner.swift" <<'SWIFT'
import Foundation
struct SpecFailure: Error { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SpecFailure(description: message) }
}
@main struct Runner {
    static func main() throws {
        try runRcmdCompatibilitySpecs()
        print("PASS rcmd compatibility routing and typed diagnostic classification")
    }
}
SWIFT
swiftc -parse-as-library \
  "$ROOT/Sources/IntentLock/RcmdKeyboardLayoutCache.swift" \
  "$ROOT/Sources/IntentLock/RcmdCompatibilityDiagnostics.swift" \
  "$ROOT/Sources/IntentLock/RcmdInputPolicy.swift" \
  "$WORK/RcmdCompatibilitySpecs.swift" "$WORK/Runner.swift" -o "$WORK/rcmd-diagnostics-spec"
"$WORK/rcmd-diagnostics-spec"
