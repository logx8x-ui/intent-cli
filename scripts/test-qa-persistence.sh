#!/usr/bin/env bash
# Exercise the actual app model without launching hotkeys, restrictions or daily data.
set -euo pipefail
cd "$(dirname "$0")/.."
qa_package_log="$(mktemp "${TMPDIR:-/tmp}/intent-persistence-package-XXXXXXXX")"
bash scripts/build-qa.sh --skip-build > "$qa_package_log" 2>&1
qa_persistence_app="$(sed -n 's/^QA app: //p' "$qa_package_log")"
qa_persistence_root="$(sed -n 's/^QA data: //p' "$qa_package_log")"
[[ -x "$qa_persistence_app/Contents/MacOS/IntentQAApp" && -f "$qa_persistence_root/.intent-qa-root" ]]
INTENT_QA_ROOT="$qa_persistence_root" "$qa_persistence_app/Contents/MacOS/IntentQAApp" --qa-persistence-checks
printf 'Isolated render: %s/naming-slots-preview.png\n' "$qa_persistence_root"
