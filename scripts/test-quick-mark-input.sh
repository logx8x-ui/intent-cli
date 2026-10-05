#!/usr/bin/env bash
# Test the production CGEvent decoder/reducer without posting desktop input or
# building the application. The same fixtures also run in IntentCoreSpec.
set -euo pipefail
cd "$(dirname "$0")/.."
spec_dir="$(mktemp -d "${TMPDIR:-/tmp}/intent-quick-input-XXXXXX")"
swiftc -emit-library -emit-module -module-name IntentCore \
  Sources/IntentCore/QuickMarkGesture.swift Sources/IntentCore/QuickMarkKeyboardInput.swift Sources/IntentCore/OverviewSearchGesture.swift \
  -emit-module-path "$spec_dir/IntentCore.swiftmodule" -o "$spec_dir/libIntentCore.dylib"
swiftc -parse-as-library -I "$spec_dir" -L "$spec_dir" -lIntentCore \
  -Xlinker -rpath -Xlinker "$spec_dir" \
  Sources/IntentApp/QuickMarkExpiryTimer.swift Sources/IntentApp/QuickMarkRunDiagnostics.swift Sources/IntentCoreSpec/QuickMarkKeyboardInputSpecs.swift \
  scripts/quick-mark-expiry-spec.swift scripts/quick-mark-input-spec.swift \
  -o "$spec_dir/QuickMarkInputSpec"
"$spec_dir/QuickMarkInputSpec"
printf 'Native input test artifacts: %s\n' "$spec_dir"
