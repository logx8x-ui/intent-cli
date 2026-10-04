# Firefox cross-desktop startup acceptance — October 5, 2026

## Installed profile and package

- Daily Firefox profile: `ykomjweq.default-release`, browser PID31075. Installed Intent at the time of the reproduction was source `cd10a8c`, app UUID `17A2B80B-781F-3EE0-8936-C71C2D0474D2`.
- Installed temporary Browser Guard0.2.29 through Firefox's normal `about:debugging` file picker. ZIP SHA-256: `2d6da9abe3b0e2d1a8c6c8957ff6b00b37e4ea4bd2774a8098d29f4d1e3374c6`.
- `Temporary Extensions (1)` identifies Intent Browser Guard at the exact submitted ZIP path. A fresh native heartbeat reports0.2.29 and `native-window-visibility-v1`.
- The permanent signed0.2.28 package remains underneath the temporary update. This is **not** permanent-update or browser-restart acceptance. No signature protection, private-window permission, or permanent extension was changed.

## Reproduction

Created disposable tabs through Firefox's native UI in QA window CG13770: two Example Domain pages and one pre-session Google search. Selected only the two Example Domain tabs, enabled Tab searches and Stopwatch, and left Add as you go off.

Session `A8CB73A5-0840-4A2B-AD0F-97F7EBB99CBF` stopped during startup with the specific blocked-Firefox-window safety error. Therefore no active tab-click, search, or normal-finish acceptance is claimed for this session.

The plan uniquely identifies browser window303 as native CG12687 by its exact title and `(0,39,1710,1073)` bounds. This older window is on another desktop. Its descriptor reports `maximized`; being off screen is not evidence of minimization.

Read-only accessibility comparison after selecting each window through Firefox's ordinary Window menu:

- With QA CG13770 in front, Firefox's AXWindows contains13770,11783,11787 and helper windows, but omits12687.
- With Debugging CG12687 in front, AXWindows contains12687 and one helper, but omits the other three ordinary windows.12687 reports AXMinimized=false and AXFullScreen=false.
- AXChildren gives the same window set plus the menu bar; it does not expose the missing window.
- The unfiltered CG lifetime inventory includes all four native windows in both cases.

`FocusVisibilityController.element` uses AXWindows after CG identity matching. The absent AX element produces `accessibilityUnavailable`; the three-second enforcement deadline safely stops the intention. This is a confirmed cross-desktop AX reachability defect, not a tab-selection pass and not an identity-match failure.

## Cleanup and next boundary

The old search tab returned to its source, all three disposable tabs remain intact, and the empty parking holder closed. The rules are inactive and `hidden-workspace.json` is empty. No user window or tab was closed.

Desktop ownership was handed to the separate native-HUD task only after this inactive, empty-journal check. Root then continued source-only work.

Do not fix this by treating an off-screen, unminimized window as successfully hidden. A browser-API delegation would need durable ownership, exact process/session fencing, confirmed effects, cancellation across Finish, and a separately verified restoration route. Merely calling browser minimization would bypass the current ownership contract and reintroduce the known restoration-focus failure.

Normal whole-window completion still fails the strict quiet-finish requirement in the previously recorded Chrome test. The requested restoration semantics and physical-key acceptance remain separate unresolved boundaries.

## Bounded post-minimization probe

After the native-HUD task handed back the desktop, selected303 through Firefox's Window menu and clicked its ordinary minimize control. Then selected working window13770 through the same menu. No intention was active and no ownership ledger was injected.

With13770 back on screen, the same Firefox process now exposes12687 through AXWindows with AXMinimized=true, alongside the three main-desktop windows. Thus minimization makes this specific other-desktop window discoverable to the native restoration path. Evidence: `/tmp/intent-firefox-303-after-minimize.json` and `/tmp/intent-firefox-303-minimized-other-desktop.json`; read-only probe `/tmp/intent-firefox-ax-cg-probe.py`.

Restored303 through the ordinary Window menu, then returned to13770. All tabs were preserved. This proves post-minimization discoverability, **not** browser-delegated minimization, native restoration, or quiet finish. A new effect protocol still requires implementation and its own tests before this startup defect is fixed.

## Related initial-workspace readiness regression

An independent executable fixture against `c424b0e` confirms that Add as you go can finish its initial visibility phase after a native plan acknowledgment, before any window has actually been minimized. With one selected window and one fully blocked normal window, the first `syncInitial` marks `initialSession` ready while window2 remains `normal`; the next call publishes an empty whole-window plan. This can remove the unresolved claim from the native enforcement policy before its existing deadline.

Evidence: `/Users/loganmondi/.codex/artifacts/intent-firefox-bootstrap-baseline-20261005/initial-readiness.cjs` and `result.log`. The fixture uses in-memory browser state and the actual visibility module; it performs no desktop or browser operations. Its expected readiness assertion fails on the installed-source baseline. The existing broad fixture's immediate-ACK expectation also needs correction; a test that merely accepts every plan cannot establish successful hiding.

Acceptance requires a native AX verification receipt for the exact process, profile, intention occurrence and still-claimed window before initial setup advances. New tabs/windows created after the frozen initial inventory must remain permitted. Browser acknowledgment, an off-screen CG window, or waiting a fixed extra interval must not count as verified minimization.

The cross-desktop implementation was developed in isolation before integration. A context lost after browser dispatch but before a durable settled result has an unavoidable uncertainty: later AX state alone cannot distinguish Intent's effect from a later user action. Such work must not be replayed or speculatively restored; retain its exact ownership until conclusive effect or lifetime evidence. This is not a guarantee of bounded recovery after an extension-context crash.

## Integrated 0.2.32 and live acceptance

Integrated the reviewed, frozen candidate based on `c424b0e`; combined patch SHA-256 `16799f15e9732000bb115aeba406ee216dab6d2fa3c128a8c25ce13cf7d58e20`. Browser manifests and native bundled version were then updated together to0.2.32.

The Firefox-only fallback is one-shot and bound to the process lifetime, profile, intention occurrence and unique native window. Native ownership is saved before an offer is published. Only a settled browser effect followed by native AXMinimized confirmation graduates to ordinary restoration ownership. Unknown effects are retained without replay or speculative restoration. All new app-side publication locking is nonblocking. Chrome does not load the Firefox executor. Add-as-you-go initial setup now waits for exact native verification rather than treating a plan ACK as hiding success.

Source-stable actual-checkout gates passed:

- `npm run test:session-ui`: `/tmp/intent-032-session-ui.log`, evidence `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-rXVBiUuS`; core, isolated app-model and notch checks, release build.
- `npm run test:extensions`: `/tmp/intent-032-extensions.log`, including19 new executor cases and existing lifecycle/parking/pin regressions.
- `npm run test:native-host`: `/tmp/intent-032-native-host.log`, protocol/recovery/closure/profile/performance gates.
- Extension lint0 errors/notices/warnings, release readiness, and both packages built.
- Development install: `/tmp/intent-032-install.log`. Installed `/Users/loganmondi/Applications/Intent.app`, bundle `dev.loganmondi.intent`; app UUID `87F06DE3-46F7-3069-A9BD-2BE8E0E94E39`, embedded host UUID `39B549B0-EB2C-3BFE-9031-D8B2D091A39C`, matching built UUIDs and deep strict codesign verification.
- Fresh Firefox and Chrome native heartbeats reported0.2.32. Firefox was updated through the normal temporary-addon file picker; signed0.2.28 remains underneath. Permanent installation/restart acceptance remains outstanding.

Live runs used the existing disposable QA tabs and preserved user windows/tabs:

1. `5884E119-7170-4010-AB2F-08BF1ABF2853`: two Firefox tabs, no modifications. The previously failing other-desktop browser303/native12687 went prepared -> issued -> settled -> native AXMinimized=true. Active observation exceeded48 seconds, current-revision native receipts included3,9,303. Ordinary Sidebery clicks switched both allowed tabs. Finish returned the pinned old search and left rules inactive/journal empty.
2. `A59A3907-7E22-4DBA-987F-D9629CA42FC3`: same selection +Add as you go. Native receipt verified3,9,303 at revision14 before claims cleared at revision15. Original windows stayed minimized, a fresh example.net tab loaded, switching between new and selected tabs worked, and a newly opened Calculator was usable. Calculator and only the newly created test tab were closed afterwards. Finish inactive/journal empty.
3. `F18B146C-E3F5-4164-8052-2A4A3E50481B`: same selection +Tab searches +Stopwatch. Active observation exceeded79 seconds; HUD showed elapsed1:34. Fresh Google search loaded, selected/search tab switching worked, and navigating that search-only tab to example.net returned to search results. Finish inactive/journal empty; only the fresh search tab was closed.
4. `ACEA911B-AB48-420C-896A-29E9B9FBC796`: Chrome Logavix profile, two allowed tabs +Add as you go. Selected/new-tab switching and a fresh website worked; excluded pinned search returned pinned/inactive in its original position. Finish inactive/journal empty. This does not establish coverage of other Chrome profiles (see below).

Filtered observations: `/tmp/intent-032-first-session.jsonl`, `/tmp/intent-032-additions-session.jsonl`, `/tmp/intent-032-search-session.jsonl`, `/tmp/intent-032-chrome-additions-session.jsonl`; native checks `/tmp/intent-032-first-active-ax.json`, `/tmp/intent-032-additions-active-ax.json`, `/tmp/intent-032-first-finished-ax.json`. These are sampled UI/native observations, not physical shortcut delivery, sub-frame animation or exhaustive subjective fluidity proof.

One completion observation returned a ScreenCaptureKit -3811 capture error. Passive process checks confirmed Intent, Firefox, Chrome and ChatGPT still running with unchanged browser/ChatGPT PIDs; the next AX read succeeded without any restart. No new production-app crash report appeared. This is not a guarantee against future computer-use crashes.

## Next separate defect: incomplete Chrome profile coverage

The Chrome run exposed a pre-existing omission: pre-session native Chrome windows in the other, non-reporting profile remained available. The connected Logavix profile only reported its own windows; unknown-profile windows therefore produced neither a normal native claim nor a safety deadline. No credential-bearing page fields were inspected or modified.

Source trace: QuickSelection records selected tabs/apps without native window IDs; Add-as-you-go runtime becomes a deny-list and retains only existing explicit native selections for initial hiding. Native browser enforcement observes only profile-reported `plan.windows`, with no complete-native-window coverage gate. Bundle-level heartbeat readiness is not per-profile coverage.

This needs its own reproduction and fix. The four scoped runs above do not certify all Chrome profiles or tester readiness. Strict quiet finish remains separately unresolved; menu-driven completion does not prove physical-key or unchanged-foreground acceptance.
