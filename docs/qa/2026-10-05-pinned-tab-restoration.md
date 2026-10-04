# Pinned-tab restoration — Browser Guard0.2.30

## Confirmed defects and scoped fixes

Chrome cross-window moves can clear a tab's pinned state. Intent now records an unfinished pin repair, reapplies the pin after its move, reads back the result, and retains ownership for retry after failed or silently ignored updates. A successful repair ends that pin ownership; later user choices are preserved.

An Intent-owned return has a separate persisted phase. A tab manually returned by the user is not repinned at completion. Firefox marker recovery distinguishes an already-returned tab or a same-process tab moved into a third window from an actual holding window.

Failed reads no longer establish that a moved tab closed. Only a successful inventory confirming absence releases that ownership; otherwise restoration retries later.

Both pinned-position repair and final order normalization used to risk pulling a concurrently moved tab back into its old window. They now verify its current identity and use within-window index moves rather than specifying a destination window.

No native window protocol or release feed changes are included. The cross-desktop Firefox startup defect and strict quiet-finish failure remain separately tracked.

## Automated evidence

- 12 initial pin regressions fail against the previous repository source and pass with this fix.
- 16 additional review cases fail against the first candidate;3 control cases already pass.
- 4 final-order race cases fail before the normalization fix and pass afterward.
- All35 targeted cases plus the full existing visibility suite pass.
- The complete `npm run test:extensions` suite passes in the isolated source mirror, including Firefox/Chrome rule and background behavior, idle work, popup, visibility transport and website features.
- Mozilla validator:0 errors,0 warnings,0 notices.
- After applying the reviewed patch, every browser source byte and the changed test harness match that passing mirror. `test-release-readiness.cjs` passes with matching Firefox, Chrome and native-host bundled version0.2.30.

Durable candidate and before/after evidence are under `/Users/loganmondi/.codex/artifacts/intent-pin-candidate-20261004/`. The final patch SHA-256 is `32b90f623b2c2a05b338adb555bb80475ee1ac2998c604f3c3b0cde07ad90c56`.

## Limits

Moving, pinning and persisting metadata are separate browser API operations. This does not make them transactional across abrupt process termination. An exactly concurrent user move can still change a tab's order within its new destination, but the repair no longer pulls it across windows. Full-process Chrome identity migration and pre0.2.29 legacy holder migration are outside this scoped fix.

Installed-profile acceptance must be recorded separately; the tests above do not establish physical shortcut behavior or human-perceived tab responsiveness.

## Installed checks on October 5

Installed the matching development app and host with `env PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin ./scripts/install-dev.sh`; release builds and deep strict signing passed. The ordinary PATH exposed a broken Homebrew Python/libexpat import during the first attempt; the successful rerun used system Python without changing the machine's Python installation. App UUID: `8D9DB5F9-2194-3B0A-9A71-27E32E5BEA10`; host UUID: `C0A4A50D-79CD-382B-9A29-A536A4E4774F`.

- Chrome Logavix profile: fresh 0.2.30 heartbeat. A disposable pinned Google search tab was blocked in a blacklist intention. It remained pinned in the holding window; both allowed tabs could be clicked. After menu Finish it returned at index0, still pinned, without selecting itself. Verified in the native tab strip and the next browser snapshot. Session `1DB03DE4-0C3C-40DC-AB6A-BE5993764651`.
- Firefox default profile `ykomjweq.default-release`: loaded the 0.2.30 ZIP through the ordinary temporary add-on picker; fresh heartbeat verified. In a blacklist intention with Stopwatch, disposable tab36 stayed pinned while parked in window852. Both permitted Example Domain tabs switched by Sidebery clicks. After menu Finish the original three-tab window had the search tab pinned at index0 and the prior Example Domain tab selected; its context menu showed Unpin. Session `BDC100FE-8323-432D-9831-EF07889139BC`. This is temporary-install acceptance, not signed/restart acceptance.
- The passive finish traces do **not** pass the strict quiet-finish verifier: CUA menu interaction first foregrounded Intent, and the guard subsequently returned to Firefox. Do not count them as physical shortcut or no-corrective-focus passes. Existing whole-window Dock-animation failure remains open.

### Cleanup issue found by these checks

The native hidden-workspace journal retains the two parked-window entries even after tabs have returned. Raw WindowServer inventory still contains native windows15128/15183, so the existing lifetime probe correctly cannot infer closure. Firefox's normal Window menu has no holder; its fresh session recovery file puts parked.html only in closed windows, not in live windows. A browser-confirmed, identity-bound closure handoff is needed; do not erase ownership merely because a window is offscreen or missing from a truncated diagnostic. The prior `/tmp/intent-front-window` helper truncates the browser window list to20 entries.

### Computer-control interruption

During the Firefox file picker, SkyComputerUseService crashed with EXC_BAD_ACCESS in the SkyLight window-notification callback. Intent, Firefox and the ChatGPT/Codex process remained running. Resetting only the CUA session reconnected successfully; the picker was inspected before continuing one input per dialog transition. No browser or user-app restart was performed.
