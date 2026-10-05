#!/usr/bin/env bash
# Run a built Swift spec only after proving its default stores use a private QA
# root. Never launch a bare lifecycle spec against the daily recovery ledger.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ $# == 1 && -x "$1" ]] || { printf 'Usage: run-isolated-spec.sh EXECUTABLE\n' >&2; exit 2; }
qa_spec_source="$1"
qa_spec_data="$(mktemp -d "${TMPDIR:-/tmp}/intent-qa-XXXXXXXX")"
qa_spec_bin="$(mktemp -d "${TMPDIR:-/tmp}/intent-spec-XXXXXXXX")"
chmod 700 "$qa_spec_data" "$qa_spec_bin"
printf 'Intent isolated QA data v1\n' > "$qa_spec_data/.intent-qa-root"
mkdir "$qa_spec_bin/probe"
swiftc -parse-as-library Sources/IntentCore/IntentEnvironment.swift scripts/test-qa-isolation.swift -o "$qa_spec_bin/probe/IntentQASpec"
env INTENT_QA_ROOT="$qa_spec_data" "$qa_spec_bin/probe/IntentQASpec"
cp "$qa_spec_source" "$qa_spec_bin/IntentQASpec"
if [[ "${CI:-}" == "true" ]]; then
  codesign --force --sign - "$qa_spec_bin/IntentQASpec"
  codesign --verify --strict "$qa_spec_bin/IntentQASpec"
fi
printf 'Isolated spec: %s\nQA data: %s\n' "$qa_spec_bin/IntentQASpec" "$qa_spec_data"
env INTENT_QA_ROOT="$qa_spec_data" "$qa_spec_bin/IntentQASpec"
