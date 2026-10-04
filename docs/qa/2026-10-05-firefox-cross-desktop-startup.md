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
