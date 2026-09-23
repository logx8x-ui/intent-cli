#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
python3 scripts/test-development-updates.py
VERSION="${1:?version required}"
BUILD="${2:?monotonic build required}"
[[ "$VERSION" =~ ^[0-9A-Za-z.-]+$ && "$BUILD" =~ ^[0-9]+$ ]] || exit 2
OUT="$ROOT/dist/beta/$BUILD"
APP="$OUT/Intent.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for product in IntentApp IntentNativeHost; do swift build -c release --product "$product"; done
cp .build/arm64-apple-macosx/release/IntentApp "$APP/Contents/MacOS/IntentApp"
ditto .build/arm64-apple-macosx/release/Intent_IntentApp.bundle "$APP/Contents/Resources/Intent_IntentApp.bundle"
cp Assets/Intent.icns "$APP/Contents/Resources/Intent.icns"
# Use the same privacy and URL-handler declarations as local installation.
python3 - "$APP/Contents/Info.plist" "$VERSION" "$BUILD" <<'PLIST'
import pathlib,plistlib,sys
source=pathlib.Path('scripts/install-dev.sh').read_text()
xml=source.split('<<PLIST\n',1)[1].split('\nPLIST',1)[0]
d=plistlib.loads(xml.encode());d['CFBundleShortVersionString']=sys.argv[2];d['CFBundleVersion']=sys.argv[3]
# Public beta packages retain automatic updates, unlike a local feature build.
d.pop('IntentDevelopmentBuild', None)
with open(sys.argv[1],'wb') as f: plistlib.dump(d,f)
PLIST
scripts/configure-supabase-bundle.sh "$APP/Contents/Resources/Intent_IntentApp.bundle" 0
scripts/embed-update-components.sh "$APP"
codesign --force --sign - --identifier dev.loganmondi.intent --requirements '=designated => identifier "dev.loganmondi.intent"' "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$OUT/updates" "$OUT/kit"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/updates/Intent-$BUILD.zip"
ditto "$APP" "$OUT/kit/Intent.app"
cp scripts/install-beta.command "$OUT/kit/Install Intent.command"
cat > "$OUT/kit/READ ME.txt" <<'NOTE'
Intent beta — Apple Silicon Macs, macOS 13 or newer.
This beta is not yet Apple-notarized. Apple may require approval in System Settings > Privacy & Security before the installer/app can run.
Open Install Intent.command. It installs into your Applications folder and preserves existing data on an update.
A fresh install after removing Intent starts with an empty workspace and onboarding.
After this one installation, Intent checks for signed updates automatically each hour and downloads them in the background. Finish your intention before restarting to apply an update.
Browser setup is guided inside Intent. Chrome stays installed; the temporary Firefox tester extension must be reloaded after Firefox restarts.
NOTE
ditto -c -k --sequesterRsrc "$OUT/kit" "$OUT/Intent-Tester-Mac.zip"
shasum -a 256 "$OUT/Intent-Tester-Mac.zip" "$OUT/updates/Intent-$BUILD.zip" > "$OUT/SHA256SUMS.txt"
echo "Packaged $OUT"
