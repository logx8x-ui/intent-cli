#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target IntentCore
build_path="$(swift build --show-bin-path)"
spec_dir="$(mktemp -d)"
trap 'rm -rf "$spec_dir"' EXIT
# Compile the actual app enum without the SwiftUI view, retaining one source of truth.
sed '/^struct QuickSelectionOptionsView: View/,$d; /import SwiftUI/d' Sources/IntentApp/QuickSelectionOptionsView.swift > "$spec_dir/spec.swift"
cat scripts/modifier-toggle-spec.swift >> "$spec_dir/spec.swift"
swiftc -I "$build_path" "$spec_dir/spec.swift" "$build_path"/IntentCore.build/*.o -o "$spec_dir/spec"
"$spec_dir/spec"
