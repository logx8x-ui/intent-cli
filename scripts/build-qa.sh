#!/usr/bin/env bash
# Build a separate, local-only QA bundle. Never installs, launches, registers a
# browser host, reads credentials, or stops the user's daily Intent process.
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qa_build="${INTENT_QA_BUILD_PATH:-$task_root/.build}"
qa_skip_build=false
if [[ "${1:-}" == "--skip-build" ]]; then
  qa_skip_build=true
elif [[ $# -gt 0 ]]; then
  printf 'Usage: scripts/build-qa.sh [--skip-build]\n' >&2
  exit 2
fi

cd "$task_root"
if [[ "$qa_skip_build" != true ]]; then
  swift build -c release --scratch-path "$qa_build" --product IntentApp
fi
qa_bin="$(swift build -c release --scratch-path "$qa_build" --show-bin-path)"
qa_framework="$qa_build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -x "$qa_bin/IntentApp" && -d "$qa_bin/Intent_IntentApp.bundle" && -d "$qa_framework" ]] || {
  printf 'Missing QA build products; build IntentApp before packaging.\n' >&2
  exit 1
}

qa_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/intent-qa-XXXXXXXX")"
/bin/chmod 700 "$qa_root"
printf 'Intent isolated QA data v1\n' > "$qa_root/.intent-qa-root"
qa_app="$qa_root/Intent QA.app"
/bin/mkdir -p "$qa_app/Contents/MacOS" "$qa_app/Contents/Resources" "$qa_app/Contents/Frameworks"
/bin/cp "$qa_bin/IntentApp" "$qa_app/Contents/MacOS/IntentQAApp"
/usr/bin/ditto "$qa_bin/Intent_IntentApp.bundle" "$qa_app/Contents/Resources/Intent_IntentApp.bundle"
/usr/bin/ditto "$qa_framework" "$qa_app/Contents/Frameworks/Sparkle.framework"
/bin/cp "$task_root/Assets/Intent.icns" "$qa_app/Contents/Resources/Intent.icns"

/usr/bin/python3 - "$qa_app/Contents/Info.plist" "$qa_root" <<'PY'
import plistlib, sys
info = {
    'CFBundleExecutable': 'IntentQAApp',
    'CFBundleIdentifier': 'dev.loganmondi.intent.qa',
    'CFBundleName': 'Intent QA',
    'CFBundleDisplayName': 'Intent QA',
    'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'Intent',
    'CFBundleShortVersionString': '0.0.0-qa',
    'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '13.0',
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'NSPrincipalClass': 'NSApplication',
    'LSEnvironment': {'INTENT_QA_ROOT': sys.argv[2]},
    'SUEnableAutomaticChecks': False,
    'SUAutomaticallyUpdate': False,
}
with open(sys.argv[1], 'wb') as handle:
    plistlib.dump(info, handle)
PY
/usr/bin/codesign --force --deep --sign - --identifier dev.loganmondi.intent.qa "$qa_app"
/usr/bin/codesign --verify --deep --strict "$qa_app"
printf 'QA app: %s\nQA data: %s\nNot launched or installed.\n' "$qa_app" "$qa_root"
