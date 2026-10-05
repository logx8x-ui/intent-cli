#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
for product in IntentCoreSpec PurposeMatcherSpec IntentAccountSpec; do
  swift build --product "$product"
  binary="$(swift build --show-bin-path)/$product"
  bash scripts/run-isolated-spec.sh "$binary"
done
