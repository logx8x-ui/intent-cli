#!/usr/bin/env bash
# Regression gate for session shortcuts, lifecycle and notch presentation.
# Builds source and runs opt-in isolated checks only; never installs Intent,
# registers browser hosts, starts a focus session or opens the daily app.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

qa_logs="$(mktemp -d "${TMPDIR:-/tmp}/intent-session-checks-XXXXXXXX")"
qa_build="${INTENT_QA_BUILD_PATH:-$PWD/.build}"
qa_step="preflight"
qa_step_log=""
trap 'qa_status=$?; printf "FAILED: %s (logs: %s)\n" "$qa_step" "$qa_logs" >&2; if [[ -n "$qa_step_log" && -f "$qa_step_log" ]]; then tail -n 80 "$qa_step_log" >&2; fi; exit "$qa_status"' ERR

source_fingerprint() {
  # Include untracked Swift files as well as tracked edits. Do not inspect daily
  # data, credentials, browser profiles or unrelated untracked directories.
  git ls-files -z --cached --others --exclude-standard -- Sources Package.swift Package.resolved \
    Assets/Intent.icns scripts/test-session-ui.sh scripts/build-qa.sh \
    scripts/test-quick-mark-input.sh scripts/quick-mark-input-spec.swift \
    scripts/quick-mark-expiry-spec.swift scripts/test-qa-isolation.swift \
    scripts/verify-finish-trace.cjs scripts/test-finish-trace.cjs |
    while IFS= read -r -d '' qa_input; do
      if [[ -f "$qa_input" ]]; then shasum -a 256 "$qa_input";
      else printf 'missing %s\n' "$qa_input"; fi
    done | shasum -a 256 | awk '{print $1}'
}

run_step() {
  qa_step="$1"; shift
  qa_step_log="$qa_logs/$qa_step.log"
  printf '%s...\n' "$qa_step"
  "$@" > "$qa_step_log" 2>&1
  printf 'PASS: %s\n' "$qa_step"
}

run_isolated_check() {
  # A broken QA entry point must fail rather than leave a test application
  # running indefinitely. subprocess.run terminates its child on timeout.
  env INTENT_QA_ROOT="$qa_data" /usr/bin/python3 - "$qa_app/Contents/MacOS/IntentQAApp" "$1" <<'PY'
import subprocess, sys
try:
    result = subprocess.run(sys.argv[1:], timeout=120, check=False)
except subprocess.TimeoutExpired:
    sys.exit("Isolated app check exceeded 120 seconds; child was stopped.")
sys.exit(result.returncode)
PY
}

qa_before="$(source_fingerprint)"
{
  printf 'UTC: %s\nCheckout: %s\nCommit: ' "$(date -u +%FT%TZ)" "$PWD"
  git rev-parse HEAD
  printf 'Source fingerprint: %s\nBuild path: %s\n' "$qa_before" "$qa_build"
  swift --version
  git status --short
} > "$qa_logs/provenance.log"
printf 'Session regression logs: %s\n' "$qa_logs"

run_step finish-trace-accounting node scripts/test-finish-trace.cjs
run_step native-keyboard-input bash scripts/test-quick-mark-input.sh
run_step core-build swift build --scratch-path "$qa_build" --product IntentCoreSpec
qa_debug="$(swift build --scratch-path "$qa_build" --show-bin-path)"
# Core specs call real lifecycle owners. Even a stop-before-start assertion must
# never be allowed to discover daily recovery files through their default store.
qa_core_data="$(mktemp -d "${TMPDIR:-/tmp}/intent-qa-XXXXXXXX")"
chmod 700 "$qa_core_data"
printf 'Intent isolated QA data v1\n' > "$qa_core_data/.intent-qa-root"
mkdir -p "$qa_logs/core" "$qa_logs/isolation"
cp "$qa_debug/IntentCoreSpec" "$qa_logs/core/IntentQASpec"
printf 'Core QA executable: %s\nCore QA data: %s\n' "$qa_logs/core/IntentQASpec" "$qa_core_data" >> "$qa_logs/provenance.log"
run_step isolation-build swiftc -parse-as-library Sources/IntentCore/IntentEnvironment.swift scripts/test-qa-isolation.swift -o "$qa_logs/isolation/IntentQASpec"
run_step isolation-behaviour env INTENT_QA_ROOT="$qa_core_data" "$qa_logs/isolation/IntentQASpec"
if [[ "${CI:-}" == "true" ]]; then
  run_step core-sign codesign --force --sign - "$qa_logs/core/IntentQASpec"
fi
run_step core-behaviour env INTENT_QA_ROOT="$qa_core_data" "$qa_logs/core/IntentQASpec"
run_step app-release-build swift build --scratch-path "$qa_build" -c release --product IntentApp
run_step isolated-package env INTENT_QA_BUILD_PATH="$qa_build" bash scripts/build-qa.sh --skip-build
qa_app="$(sed -n 's/^QA app: //p' "$qa_step_log")"
qa_data="$(sed -n 's/^QA data: //p' "$qa_step_log")"
qa_step="isolated-package-validation"
[[ -x "$qa_app/Contents/MacOS/IntentQAApp" && -f "$qa_data/.intent-qa-root" ]]
/usr/bin/dwarfdump --uuid "$qa_app/Contents/MacOS/IntentQAApp" >> "$qa_logs/provenance.log"
printf 'QA app: %s\nQA data: %s\n' "$qa_app" "$qa_data" >> "$qa_logs/provenance.log"
run_step app-model run_isolated_check --qa-persistence-checks
run_step notch-presentation run_isolated_check --qa-notch-checks
run_step whitespace git diff --check

qa_step="source-stability"
qa_step_log=""
if [[ "$(source_fingerprint)" != "$qa_before" ]]; then
  printf 'Source changed during this run. Rerun after edits stop; this result is not a gate pass.\n' >&2
  exit 1
fi
printf 'PASS: session regression gate (same source throughout).\n'
printf 'Evidence: %s\nIsolated previews/data: %s\n' "$qa_logs" "$qa_data"
printf 'No daily app was installed or launched. Physical keys, live focus and display/Space acceptance remain separate.\n'
