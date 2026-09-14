#!/usr/bin/env bash
set -euo pipefail
for product in IntentCoreSpec PurposeMatcherSpec IntentAccountSpec; do
  swift build --product "$product"
  binary="$(swift build --show-bin-path)/$product"
  if [[ "${CI:-}" == "true" && "$(uname)" == "Darwin" ]]; then
    codesign --force --sign - "$binary"
    codesign --verify --strict "$binary"
  fi
  "$binary"
done
