#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
BUILD="${2:-$ROOT/.build}"
mkdir -p "$APP/Contents/Frameworks" "$APP/Contents/Helpers" "$APP/Contents/Resources/BrowserGuard"
ditto "$BUILD/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$BUILD/arm64-apple-macosx/release/IntentNativeHost" "$APP/Contents/Helpers/IntentNativeHost"
ditto "$ROOT/chrome-extension" "$APP/Contents/Resources/BrowserGuard/Chrome"
ditto "$ROOT/firefox-extension" "$APP/Contents/Resources/BrowserGuard/Firefox"
/usr/bin/python3 - "$APP/Contents/Info.plist" <<'PLIST'
import plistlib,sys
p=sys.argv[1]
with open(p,'rb') as f: d=plistlib.load(f)
development=d.get('IntentDevelopmentBuild',False)
channel='development' if development else 'launch'
# Promotion publishes this separate signed feed. Development must never be
# overwritten by the public channel, and launch must never consume the beta feed.
d.update(IntentBuildChannel=channel,SUFeedURL='https://github.com/logx8x-ui/intent-cli/releases/download/intent-launch-feed/appcast.xml',SUPublicEDKey='0ZyfuMFDcoimRez7QUqWSWIfAjTVGmpndPT3J0RVuyk=',SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,SUAllowsAutomaticUpdates=not development,SUEnableInstallerLauncherService=True,SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True)
with open(p,'wb') as f: plistlib.dump(d,f)
PLIST
