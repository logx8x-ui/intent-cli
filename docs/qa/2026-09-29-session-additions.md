# Session additions — 29 September 2026

## Implemented

- Add as you go is an off-by-default restriction node saved with each intention. Session rules capture its value before startup; running-session modifier shortcuts do nothing. Open-ended whitelist enforcement allows ordinary app/window/tab navigation while persistent app bans and explicit blacklist selections retain priority.
- Stopwatch uses ContinuousClock elapsed duration (including sleep), resets per run and shares the timer/checklist controls' collapsed, hidden and restored states. It does not introduce a finish lock.
- Six reorderable modifiers preserve the saved order, append missing entries and accept successive number chords while backtick stays held.
- Firefox activation no longer awaits activity-history persistence. The native tab guard skips a full accessibility tree walk when every tab in the window is allowed, retaining address-bar guarding for restrictive sessions.
- Normal home navigation exposes Mission Control, saved intentions and workspace/general settings. Legacy canvas/AI code and saved data remain intact without normal entry points.
- Window metadata is published before captures; previews replace pixels in the same identified cards. Static placeholders replace the gathering spinner and respect Reduce Motion. Escape still invalidates pending captures.
- Actual Spotlight input has a separate event path. Only a leading/trailing backtick query and one selected application file URL from accessibility can stage an app. Changed results, non-app results and unavailable cancellation fail explicitly. No application is inferred from its name.
- Background preparation defaults on, uses nonactivating/hidden launch, displays an opening indicator and prevents Run until preparation finishes. Existing running apps are not hidden. Owned process identity includes launch date; deselection/cancellation/recovery release only owned apps. Blacklist selections do not launch apps.
- The exact requested one-time OK notice and background-opening setting are present.
- Whole-browser Spotlight selections persist through saving/replay. They retain explicit website-feature policies introduced in the parallel app-stack work.

## Integration

This branch merges `e162fce` from the parallel app-stack/site-control task. It preserves natural stacks, per-window selection, site controls and browser-profile identity routing. The waitlist was not changed.

## Automated verification passed

- IntentCoreSpec (including session additions, modifier order and held chords, legacy decoding, immutable captured policy, blacklist/preset precedence, stopwatch visibility, whole-browser replay, app stacks and restoration focus policy).
- Actual modifier enum disable/re-enable/independence/idempotence tests for all six controls.
- IntentAccountSpec and PurposeMatcherSpec compatibility.
- Complete Firefox/Chrome rule and background suites, including existing and newly created tabs under Add as you go in both modes.
- Browser idle-work and popup checks; tab-visibility restoration, suspended workers, mode reversal, owned group metadata, last window, missing destinations and serialized restoration.
- Website feature route/precedence/parity tests, including coexistence of whole-browser permission and explicit site controls in the native host.
- Native host, performance, snapshot freshness and multi-profile routing/receipt tests. Native host peak RSS: 8.1 MiB.
- Release readiness; Firefox lint with zero errors/notices/warnings; Firefox/Chrome 0.2.22 packages built.
- Optimized Swift release build and `git diff --check`.

## Installation

`scripts/install-dev.sh` installed and relaunched `/Users/loganmondi/Applications/Intent.app` without replacing saved data. Signature verification passed. Source and installed app UUID both:

`D764A07B-D27F-392E-9F48-B98E20E71559` (arm64).

Both browser components are embedded and staged at 0.2.22. The installed app is a development build, not a published/notarized release.

## Not yet accepted live

The Mac locked before this branch's UI QA; computer-use returned an explicit locked-Mac error. An unlock request is pending. No live claim is made for:

- Spotlight selected-result AX exposure/cancellation, prefix/suffix entry, changed queries, foreground preservation, one-time notice, cancellation or launch failures.
- Firefox perceptual tab-switch latency or zero flashing.
- Stopwatch rendering, dragging, actual sleep/wake, collapse/backtick hide/restore, timer/checklist coexistence and every completion path.
- Skeleton appearance, missing previews, closing while loading and mixed physical single/double-tap gestures.
- The small blue mark. Its ownership has not been established. No Intent-owned blue overlay was identified; existing browser tab-group colors are deliberately preserved. Do not remove an unrelated browser indicator by assumption.

Chrome's live default-profile extension still points to the other checkout's `chrome-extension` directory and reports 0.2.21. The new stable staged directory is `~/.intent/browser-guard/Chrome`, but switching/reloading the loaded extension requires unlocked UI. Do not overwrite the other checkout or claim matching live components.

Firefox's permanent default-profile extension is 0.2.20; the other task used a temporary 0.2.21 QA copy. A signed 0.2.22 update and restart verification remain outstanding. Mozilla signing was unavailable in the parallel task; no browser security requirement has been bypassed.

## Resume checklist

1. Verify this installed UUID and no active intention, then finish live home/settings, modifier and skeleton checks.
2. Point Chrome to the stable staged component and verify a fresh 0.2.22 heartbeat with `add-as-you-go-v1`; reload the temporary Firefox QA component for local checks, clearly distinguishing it from a permanent signed update.
3. Test Add as you go off/on, both modes, app/window/tab additions, persistent bans and prohibited mid-session changes.
4. Exercise actual Spotlight app results and keyboard input; report any macOS AX limitation rather than weakening identification.
5. Exercise stopwatch/timer/checklist completion and foreground preservation. Reproduce and attribute the blue mark before changing its owner.
6. Publish signed Firefox/browser-store updates separately when the required credentials and store workflow are available.


## Unlocked follow-up — 2026-09-30

Verified through the native macOS UI with the installed development build:

- First app click opens the naming bar. Confirming the name selects that original app.
- Add as you go and Stopwatch enable together. Clicking Stopwatch again disables it; enabling it again succeeds.
- Running the temporary `Intent QA stopwatch` intention displays an increasing elapsed counter. Collapse leaves a persistent small bar; expanding restores the still-running counter (00:00:21 observed).
- File > Finish Intention removes the running controls. Native browser-rules readback confirms `active: false`. The synthesized Shift+grave path did not finish the run; physical shortcut acceptance and exact foreground preservation remain open.
- Chrome Default/Logavix visibly loads 0.2.22 from the existing main checkout. Its manifest and background script hashes match this branch. UI reload succeeds and a fresh heartbeat includes `add-as-you-go-v1`. This supersedes the earlier 0.2.21 observation; its unpacked path is still the main checkout, not the stable staged folder.
- Firefox temporarily loads 0.2.22 from `~/.intent/browser-guard/Firefox`; fresh heartbeat includes `add-as-you-go-v1`. Temporary loading is not a permanent signed update.
- Spotlight automation times out; requested a physical Command+Space opening while independent review continues. Selected-result exposure, background launch and marker workflows remain unverified.

Codex was not restarted or reconfigured. Its Crashpad sidecars confirm browser-process crash captures at 06:41, 09:26 and 09:45 local time. Recent desktop logs contained no matching fatal/crash marker. These records establish crashes, not a root cause or a repair; no guarantee against recurrence is made.


## Browser additions live follow-up — 2026-09-30

- Ran `Intent QA additions` with Spotify selected, Add as you go and Stopwatch enabled.
- Chrome Default/Logavix: a newly created tab loaded example.com; address-bar navigation to example.org remained allowed while the intention ran.
- Firefox default profile with temporary 0.2.22 guard: a newly created tab loaded example.com; address-bar navigation to example.org remained allowed. A second fresh tab loaded example.net. Direct sidebar clicks switched to example.net and example.org without observed bounce-back. This is state-transition acceptance, not a measured perceptual latency or reload-count guarantee.
- File > Finish Intention cleared restrictions (`browser-rules.json active: false`) and removed the Stopwatch control.
- Both browsers still reported fresh 0.2.22 heartbeats with `add-as-you-go-v1` after the test.
- Apple Spotlight process is running. Computer-use selection by bundle ID and exact `/System/Library/CoreServices/Spotlight.app` path both timed out even after Logan physically opened it. Requested a physical leading-backtick Calculator submission; name-first receipt/background launch remain pending until that result is observed.
- No existing user tabs were closed. Only safe example-domain test tabs were added.
