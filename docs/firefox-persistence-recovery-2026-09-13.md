# Firefox tab connection recovery — September 13, 2026

## Cause and current recovery

The reported Cmd+G banner was `Tabs unavailable · connect Browser Guard`.
Firefox's last heartbeat was September 12 at 03:21:37 UTC; no Firefox native-host
process was running. Chrome's 0.2.8 heartbeat remained live. The active Firefox
profile was `ykomjweq.default-release`. Its persistent Mozilla-signed XPI was
0.2.5, while the prior 0.2.8 fix had been loaded through `about:debugging` and
disappeared on restart. Firefox's add-on UI showed no running Intent guard.

Loaded the tested source 0.2.8 temporarily again. Its fresh heartbeat advertises
quick selection, single-startup launch, and tab previews. Cmd+G visibly renders
both Firefox and Chrome tabs. Selecting a Firefox tab shows a green outline,
`Apps 1 · Tabs 1`, and enables Start. Escape cancels without starting a session.
This is a session-only recovery, not acceptance after a Firefox restart.

## Permanent update is submitted, not yet signed

Mozilla's developer dashboard was already authenticated, so no API credentials
were needed to submit the existing add-on's new **unlisted** version. Uploaded
`dist/firefox/intent_browser_guard-0.2.8.zip`; Mozilla validation returned zero
errors and zero warnings. Source is unminified and included in the package.

- Version: 0.2.8; Mozilla version ID: 6481707; file ID: 5025873.
- [Submission status](https://addons.mozilla.org/en-US/developers/addon/485649d659c2420c9778/versions/6481707).
- Last observed status: **Awaiting Review / Version Signature Pending**.
- No signed 0.2.8 XPI was available. Do not install the unsigned ZIP as a
  permanent extension, disable signature enforcement, or bump the live feed
  before the signed artifact is available.

To finish after approval: download the signed XPI from this version page,
verify its version and source match, install it normally (replace the temporary
copy), and verify the live connection and picker after restarting Firefox when
that will not interrupt Logan's active browsing. Publish the versioned XPI and
current download alias, verify their downloaded bytes, then advance
`firefox-updates.json` with the actual version, URL, and SHA-256 hash. The
onboarding install link currently uses the GitHub latest-release XPI alias.
No feed or GitHub release asset was changed during the pending review.

## Recurrence check

`python3 scripts/check-firefox-installation.py` checks the persistent profile XPI
independently of a temporary add-on's fresh heartbeat. It rejects missing,
outdated, unsigned, unreadable, or mismatched background packages. This is a
structural/source check; Firefox must validate the actual Mozilla signature.
The development installer now reports incomplete Firefox setup explicitly.
It preserves the successful native app installation and never silently replaces
or modifies browser-profile files.

## Verification

- Firefox and Chrome rule/background tests, reconnect backoff and idle-work
  tests passed; Firefox lint had zero errors or warnings; ZIP build passed.
- New persistent-installation regression fixtures passed, including an old
  permanent package despite a current source build.
- Native-host behavior/performance tests and IntentCoreSpec passed.
- IntentApp release build and `scripts/install-dev.sh` passed. Data preserved.
- Installer emitted the expected warning about permanent 0.2.5 vs source 0.2.8.
- After reinstall, both browsers still displayed tabs in Cmd+G; selecting a
  Chrome tab again enabled Start, and Escape cancelled without running a session.
- Full browser restart and permanent-package live acceptance remain pending
  Mozilla's signature. Browser restriction enforcement was not re-tested;
  no new restrictive session was started during this connection repair.
