# Browser connection correction — 2026-09-22

## Root cause observed

The running app was the isolated Intent QA bundle package-NDfK0F0g. The regular Firefox host registration pointed to /Users/loganmondi/Applications/Intent.app/Contents/Helpers/IntentNativeHost. Its heartbeat was in ~/.intent, reported extension 0.2.11, and lacked session-identity capabilities. The QA workspace had only a Chrome heartbeat (0.2.13). Thus Firefox was connected to a different workspace, not disconnected from its own host. The extension popup previously displayed Guard on solely from its enabled preference, including on failed status requests.

## Changes

- Chrome and Firefox popups distinguish enabled from native connection confirmed by a reply; failed status requests clear previous success.
- Disconnected bridges retry promptly on browser focus or popup opening, at most once per three seconds for foreground retries. Background exponential backoff remains unchanged.
- Ignore late responses from disconnected ports, and clear confirmation on disconnect.
- QA explains its separate test-browser connection rather than blaming the regular extension. Production recovery text describes reconnection.
- Extension source versions are 0.2.14.

## Verification

- npm run test:extensions: passed, including new popup and foreground reconnect/late reply regression checks.
- npm run extension:lint: zero errors, warnings, notices.
- swift build -c release: passed (160.35 seconds); /tmp/intent-connection-release-build.log.
- git diff --check: passed.
- Packaged and signed /Users/loganmondi/.codex/artifacts/intent-qa/package-kKYupbBK/Intent QA.app; not launched/installed.
- Live personal Firefox connection/workspace mismatch verified from process paths, host registration and heartbeat metadata.
- New popup and recovery not yet live-verified in Firefox/Chrome. No enforcement sessions started.

## Environment and release boundary

Regular app, extension and personal browser data were not replaced. A Firefox profile named Intent QA Connection was created for isolated validation; default-release was restored as default immediately. The separate process launched but native UI tooling continued targeting the original instance, preventing isolated popup verification. Its profile contains no signed-in account. The QA-only Firefox host fixture was prepared for the existing isolated root. No release or push occurred: earlier explicit QA instructions require authorization before daily-app replacement or publication.

Next: install matching development app/browser components in the daily setup only after explicit approval, then verify actual tab marking, popup status and reconnect in each browser. A signed persistent Firefox distribution is a separate publication step; source version is not evidence of deployment.

## Approved everyday installation

Logan explicitly approved replacing the normal app and matching browser components. scripts/install-dev.sh initially hit the pre-existing Homebrew Python pyexpat error; rerunning with system Python first in PATH succeeded. Normal app runs from ~/Applications/Intent.app, signature verifies, and Intent QA was quit. Saved intentions remained visible.

Firefox temporary add-on at ~/.intent/browser-guard/Firefox was reloaded through about:debugging; popup visibly displayed Connected to Intent. Chrome auto-reloaded its updated bundled component. Both normal-workspace heartbeats reported 0.2.14 with tab-session identity. In the normal app, Firefox and Chrome window clicks opened populated tab pickers, and a tab selected/deselected in each. No restriction session was started, selections cleared. Two normal native hosts were deliberately terminated while rules were inactive; both resumed fresh heartbeats within five seconds.

Remaining: Firefox permanent package is still signed 0.2.5; active 0.2.14 is temporary and will not survive restart. AMO signing credentials were absent from the environment. No permanent signing or public release performed. Physical double-backtick marking and enforcement were not tested in this installation pass.
