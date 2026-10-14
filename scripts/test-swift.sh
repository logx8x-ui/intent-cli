#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source scripts/build-jobs.sh
for product in IntentCoreSpec PurposeMatcherSpec IntentAccountSpec; do
  swift build --jobs "$INTENT_BUILD_JOBS" --product "$product"
  binary="$(swift build --jobs "$INTENT_BUILD_JOBS" --show-bin-path)/$product"
  bash scripts/run-isolated-spec.sh "$binary"
done
