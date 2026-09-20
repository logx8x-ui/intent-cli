#!/usr/bin/env bash
# Build a separate, local-only QA bundle. Never installs, launches, registers a
# browser host, reads credentials, or stops the user's daily Intent process.
set -euo pipefail

task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
qa_build="${INTENT_QA_BUILD_PATH:-$task_root/.build}"
qa_skip_build=false
qa_root=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) qa_skip_build=true; shift ;;
    --data-root)
      [[ $# -ge 2 && -n "${2:-}" && -z "$qa_root" ]] || { printf 'Provide one existing QA data root.\n' >&2; exit 2; }
      qa_root="$2"; shift 2 ;;
    *) printf 'Usage: scripts/build-qa.sh [--skip-build] [--data-root EXISTING_QA_ROOT]\n' >&2; exit 2 ;;
  esac
done

# Repackaging can retain a test workspace, but never accepts the daily data
# directory or silently creates a marker inside an arbitrary caller's folder.
if [[ -n "$qa_root" ]]; then
  qa_root="$(/usr/bin/python3 - "$qa_root" <<'PY'
import os, pathlib, stat, sys
original = pathlib.Path(sys.argv[1])
root = original.resolve()
parents = {pathlib.Path(os.environ.get('TMPDIR', '/tmp')).resolve(), pathlib.Path('/private/tmp').resolve()}
valid = (original.is_absolute() and root.parent in parents
         and root.name.startswith('intent-qa-') and len(root.name) > len('intent-qa-')
         and root.is_dir() and stat.S_IMODE(root.stat().st_mode) == 0o700)
marker = root / '.intent-qa-root'
if not valid or not marker.is_file() or marker.read_text() != 'Intent isolated QA data v1\n':
    sys.exit('Refusing an invalid existing QA data root; use a private marked intent-qa-* folder.')
print(root)
PY
)"
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

if [[ -z "$qa_root" ]]; then
  qa_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/intent-qa-XXXXXXXX")"
  /bin/chmod 700 "$qa_root"
  printf 'Intent isolated QA data v1\n' > "$qa_root/.intent-qa-root"
fi

# Keep signed code outside the system's temporary cleanup tree. Copied resources
# with old ditto-preserved timestamps disappeared overnight from a QA bundle in
# temp while its freshly signed Mach-O remained; the signature then failed.
# A unique artifact folder also means --data-root never replaces a running app.
qa_artifacts="$HOME/.codex/artifacts/intent-qa"
/bin/mkdir -p "$qa_artifacts"
qa_artifacts="$(cd "$qa_artifacts" && pwd -P)"
/usr/bin/python3 - "$qa_artifacts" <<'PY'
import os, pathlib, sys
artifacts = pathlib.Path(sys.argv[1]).resolve()
for temporary in {pathlib.Path(os.environ.get('TMPDIR', '/tmp')).resolve(), pathlib.Path('/private/tmp').resolve()}:
    if artifacts == temporary or temporary in artifacts.parents:
        sys.exit('QA app artifacts must be outside the system temporary directory.')
PY
qa_package="$(/usr/bin/mktemp -d "$qa_artifacts/package-XXXXXXXX")"
qa_app="$qa_package/Intent QA.app"
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

# Refresh only this newly copied bundle, never the SwiftPM source artifacts.
# Do not follow framework symlinks while updating their own timestamps.
/usr/bin/python3 - "$qa_app" <<'PY'
import os, sys, time
stamp = time.time()
for directory, directories, files in os.walk(sys.argv[1], followlinks=False):
    for name in directories + files:
        os.utime(os.path.join(directory, name), (stamp, stamp), follow_symlinks=False)
    os.utime(directory, (stamp, stamp), follow_symlinks=False)
PY
/usr/bin/codesign --force --deep --sign - --identifier dev.loganmondi.intent.qa "$qa_app"
/usr/bin/codesign --verify --deep --strict "$qa_app"
printf 'QA app: %s\nQA data: %s\nNot launched or installed.\n' "$qa_app" "$qa_root"
