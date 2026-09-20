#!/usr/bin/env bash
# Deterministic/integration checks only. This does NOT run the live desktop smoke
# matrix or authorize installing/publishing the app. AI/Purpose/Scheduler feature
# suites are deliberately excluded; shared CoreSpec assertions still compile/run.
set -euo pipefail
cd "$(dirname "$0")/.."
qa_logs="$(mktemp -d "${TMPDIR:-/tmp}/intent-qa-checks-XXXXXXXX")"
printf 'QA logs: %s\n' "$qa_logs"
for product in IntentCoreSpec IntentAccountSpec; do
  swift build --product "$product" > "$qa_logs/build-$product.log" 2>&1
done
for product in IntentApp IntentNativeHost Intent; do
  swift build -c release --product "$product" > "$qa_logs/release-$product.log" 2>&1
done
qa_debug="$(swift build --show-bin-path)"
for pass in 1 2 3; do
  {
    "$qa_debug/IntentCoreSpec"
    "$qa_debug/IntentAccountSpec"
    npm run test:extensions
    node scripts/test-native-host.cjs
    node scripts/test-native-host-snapshot-refresh.cjs
    npm run test:release-readiness
  } > "$qa_logs/regression-pass-$pass.log" 2>&1
  printf 'Automated regression pass %s/3 passed (not live UI acceptance).\n' "$pass"
done
node scripts/test-native-host-performance.cjs > "$qa_logs/native-host-performance.log" 2>&1
npm run extension:lint > "$qa_logs/extension-lint.log" 2>&1
npm run extension:build > "$qa_logs/firefox-package.log" 2>&1
npm run extension:build:chrome > "$qa_logs/chrome-package.log" 2>&1
node scripts/test-download-page.mjs > "$qa_logs/download-page.log" 2>&1
/usr/bin/python3 scripts/test-download-kits.py > "$qa_logs/download-kits.log" 2>&1
/usr/bin/python3 scripts/test-qa-chrome.py > "$qa_logs/qa-chrome-isolation.log" 2>&1
/usr/bin/python3 scripts/test-qa-firefox.py > "$qa_logs/qa-firefox-isolation.log" 2>&1
/usr/bin/python3 scripts/test-qa-packaging.py > "$qa_logs/qa-packaging.log" 2>&1
swiftc -parse-as-library Sources/IntentCore/IntentEnvironment.swift scripts/test-qa-isolation.swift -o "$qa_logs/IntentQASpec"
"$qa_logs/IntentQASpec" > "$qa_logs/qa-isolation.log" 2>&1
swiftc -parse-as-library Sources/IntentApp/IntentFreshInstallation.swift scripts/test-fresh-install.swift -o "$qa_logs/IntentFreshInstallSpec"
"$qa_logs/IntentFreshInstallSpec" > "$qa_logs/fresh-install.log" 2>&1
git diff --check
printf 'All automated checks passed; live smoke/visual checks remain separate.\n'
