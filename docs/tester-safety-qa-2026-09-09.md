# Tester safety fixes — September 9, 2026

## Scope and outcome

Development changes for the tester lockout, sluggish rejection, Mission Control click policy, Leisure, shortcut reset, onboarding app evidence, and green preset startup behavior. This is not a signed public release and is not proof that the friend's exact freeze has been reproduced or eliminated.

The requested native Mission Control selection revamp is **deferred**, as the user allowed. No supported integration was established for replacing Dock's Spaces strip, retaining custom window selection, or attaching interactive tab bubbles. The existing Quick Focus picker remains unchanged; it must not be described as native Mission Control. Finishing a temporary selection still offers Save.

## Changes

- First app-process load clears persisted Zero Drift and browser restrictions. Already-due schedule occurrences are marked handled before the scheduler starts, preventing immediate catch-up relocking on recovery. Future scheduled sessions remain enabled.
- Safety Stop (`Control–Option–Command–Escape`) releases active and idle locks, clears pending start flows and browser rules, and cancels Zero Drift. It is available through the input hook, global hotkey, File menu, and status menu. Safety cleanup does not close the user's session apps.
- Disabled/unhealthy input taps stop enforcement instead of repeatedly re-enabling. Accessibility work during click classification has a short timeout and traversal deadline. Unknown click ownership fails open rather than swallowing every click.
- Unallowed regular-app activation bypasses the old Space grace and prioritizes the most recently permitted app. This is app-level recovery, not a new exact-window-ID enforcement system.
- Known forbidden Mission Control tiles are swallowed without refocusing/dismissing Mission Control. Known permitted owners are accepted. Unknown/unresolved tiles can pass and then be rejected by foreground enforcement; exact no-op behavior is not guaranteed for ambiguous native tiles.
- Leisure creates no blocking input tap or focus-enforcement observers, permits all apps, and retains configured startup resources, even with a stale blacklist flag.
- Settings includes Reset shortcuts to defaults. Finish shortcut updates propagate into active locks. The reset preserves preferences if registration fails.
- Onboarding uses LaunchServices/Spotlight use-count and last-used metadata instead of hard-coded installed-app choices. Minimum three uses, last use within thirty days, top twelve by count. Missing metadata means manual selection, not guessed apps. This is usage evidence, not a measurement of foreground time.
- Always-allowed green presets contribute runtime startup exclusions without adding visible restriction nodes or persisting derived metadata. They remain permitted without auto-launching.

## Verification

- `IntentCoreSpec`: passed, covering immediate whitelist rejection, auxiliary UI, Intent-owned controls, known/unknown Mission Control click policy, unrestricted Leisure, measured app ranking, and preset startup exclusions.
- `PurposeMatcherSpec`: passed.
- `IntentAccountSpec`: passed.
- `npm run test:extensions`: passed Firefox and Chrome rule/background specs and reconnect/performance assertions.
- Production CLI, app, and native host builds passed through `scripts/install-dev.sh`; development app installed at `~/Applications/Intent.app`, matching native hosts installed. Existing user data retained.
- Installed settings: changed Open Intent to a temporary custom binding, clicked Reset, and visually confirmed the default Open/Finish values restored without errors.
- Installed Leisure: existing Leisure session showed active, an unlisted Chrome Example Domain page remained usable, and browser rules were inactive. No claim of physical trackpad coverage.
- Installed Safety Stop: ended Leisure and a one-minute Zero Drift run before expiry. During Zero Drift, Settings remained clickable. Release confirmation appeared; Zero Drift runtime file was absent and browser rules inactive afterward.
- Installed restart recovery: started a two-minute Zero Drift run, verified 113 seconds remained, and ran the already-built development installer to restart the app before expiry. The reopened app showed Zero Drift False with no active session, and the persisted Zero Drift file was absent. The corrected recovery warning was also visible in the installed app.
- Installed temporary Quick Focus: selected two apps, started with second Cmd+G, finished using File → Finish Intention, and observed the Save prompt with two apps. Discarded the QA-only candidate and closed the test browser tab.

## Remaining acceptance limits

- Native Dock UI inspection timed out. Physical Mission Control/Spaces clicking, trackpad animation, immediate bounce latency, and the friend's original freeze remain unverified end to end. Deterministic policies and bounded recovery passed; these are not equivalent evidence.
- In-app synthetic shortcut delivery worked. Global physical key delivery outside Intent was not independently measured.
- No Mac reboot was performed. App-process restart recovery passed; this is not a physical reboot test.
- No new browser permissions were granted. Firefox's previously installed extension version mismatch is outside this patch; no claim that it was updated or that Firefox exact-tab Quick Focus passed.
- No new-profile AI onboarding request was sent. Filtering and fallback were tested in code, and measured choices appeared in installed settings.

Apple references consulted: [AX messaging timeout](https://developer.apple.com/documentation/applicationservices/1459345-axuielementsetmessagingtimeout), [last-used metadata](https://developer.apple.com/documentation/coreservices/kmditemlastuseddate), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit).
