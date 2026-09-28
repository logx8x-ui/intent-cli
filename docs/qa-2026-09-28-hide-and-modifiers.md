# Intent: hiding, shortcuts, modifiers and waitlist review

Request date: 2026-09-28. Development branch: codex/name-first-intentions.

## Implemented

- Preview joins the default always-allowed apps. Existing customized and explicitly empty lists are preserved.
- Hide mode no longer starts the native blur controller. Both Browser Guards put blocked tabs from mixed windows into minimized holding windows; whole blocked windows are minimized. No user tab is closed by this visibility mechanism.
- Firefox uses parking instead of tabs.hide, because Sidebery can still display natively hidden tabs. State is saved before moves, with Firefox session markers for recovery. Pinned tabs, native group metadata, pre-existing minimization and other extensions' hidden state are preserved in covered cases. Private tabs use separate private holding windows when Browser Guard has access.
- Old unselected search/new-tab pages are not eligible under Searches. Only fresh search tabs from the current intention qualify, plus explicitly selected tabs. Search results cannot navigate into websites. Chrome network exceptions use the same selected/fresh identities.
- The native highlighted tab group is captured before the name prompt, which can otherwise clear sidebar selection, then validated against the same browser lifetime/window.
- Arrow collapses timer/checklist to a bar; backtick independently hides/shows it. State refresh does not reopen hidden controls. Header dragging avoids OS window tiling; expansion keeps the header reachable.
- Modifier clicks enable and open settings directly. Searches toggles directly with no settings sheet. Enable checkboxes are removed; concise hover hints appear after one second. Modifier shortcuts toggle and allow several number presses during one backtick hold.
- Closing overview cancels modifier hints and staged panels, including delayed popover dismissal after reordering.
- Native helper and both extension manifests advertise 0.2.20 consistently.

## Automated verification

- Full `npm test`: passed (core, purpose matching, account, Firefox/Chrome behavior, installation checks, idle workload, popup, tab visibility, native host, native host performance/freshness, 14 AI service tests, release readiness, Firefox lint).
- Quick gestures: 100 repeated sequences, including held-prefix number chains, retoggle and repeat-key handling.
- Layout: 1–50 windows.
- `scripts/test-modifier-toggles.sh`: all four disable/re-enable, independence, idempotence and end-time removal checks passed.
- Added regressions for old versus fresh search tabs, service-worker resume/new-session identity, holding pages initially reported as about:blank, silent move failures, Sidebar restore reordering, pinned/native groups, split pairs, lost source windows, persistence failures, and private/normal separation.
- Release app/native-host build and matching development install succeeded. Firefox lint: zero errors and warnings. Both extension packages built.
- Latest private-window change was checked with the visibility spec and extension lint/build after the full suite; it does not change native code.
- Follow-up 0.2.20: a delayed Sidebery reorder test fails on 0.2.19 and passes with settling verification (two quiet observations). Firefox/Chrome extension suites, lint, packages, release readiness, and matching development installation passed. The installation used system Python after Homebrew Python failed to load its expat library.

## Installed and observed

Installed development app: ~/Applications/Intent.app, bundle dev.loganmondi.intent.

Native live checks:
- Preview appears in default allowed apps.
- Timer and Checklist open directly enabled, without the extra checkbox.
- Searches enables/disables directly without a popover.
- Live modifier reorder/close: dragged Timer from position 1 to 4, verified shortcut order changed, closed overview and verified the modifier strip disappeared, reopened and restored the original order.
- Three-minute timer plus two tasks: collapse, drag and expand worked. First checkbox left the intention running; second ended it early and cleared active rules and hidden-workspace state.

Firefox normal profile with Sidebery, signed 0.2.18 intermediate build:
- A controlled window containing one selected page, one unselected page and an old Google-results tab showed only the selected page during Hide mode.
- After the one-minute timer, all 24 pre-test tab IDs were still present in their original windows; no user tabs were lost.
- This live test exposed a leftover blank holding window and changed order for two returning test tabs. The holding-page cleanup passed the 0.2.19 retest; the order check exposed a further asynchronous Sidebery race, addressed in 0.2.20.

Firefox signed 0.2.19 live retest:
- Mozilla approved the package, installed permanently in ykomjweq.default-release; installed background/visibility source matched the package and heartbeat reported 0.2.19.
- A three-minute session with Sidebery showed only the selected fixture; the old Google-results tab and blocked fixture moved out of the working window.
- Fresh Google search worked; clicking a result and typing an unrelated destination remained on the search page. Normal in-page navigation from the selected fixture succeeded.
- All 25 original tab IDs returned to their original windows, the new search tab survived, and the holding page/window was removed. Two tabs changed order after immediate readback: a delayed sidebar attachment event was still pending. 0.2.20 now waits for stable order before dropping recovery metadata.

Firefox final signed 0.2.20 acceptance:
- Approved by Mozilla (version 6520272, file 5064418), validation zero errors/warnings, permanently installed in the default-release profile. Installed source matches the tested package, signature present, heartbeat 0.2.20. Signed artifact: dist/firefox/Intent-Firefox-Extension-0.2.20.xpi.
- A fresh one-minute session hid the three unselected tabs from the controlled working window; a fresh search tab remained usable.
- After completion, all 26 pre-test tab IDs returned to their original windows and indices with zero order differences. The new search tab was retained after the original tabs. No holding page or extra holding window remained. Active rules cleared.

Chrome 0.2.20 live acceptance after restarting Chrome:
- Existing Logavix profile reconnected. Two windows both titled New tab and with identical geometry reproduced an empty overview tab list despite a healthy bridge.
- Overview now resolves ambiguous windows by focusing each existing active tab through the session-validated bridge, pairing fresh extension focus with native window identity, and caching that pairing only for the open overview/browser lifetime. Both previews were checked: one showed its four tabs and the other its single tab, with no manual window selector.
- Core specs passed, including 100 gesture sequences and 1–50 window layouts; release app/native-host builds and development installation passed.
- A controlled Chrome intention with Searches enabled left only the selected fixture visible; old New tab, hidden fixture and pre-session search tabs were removed from the working strip.
- Normal in-page navigation from the selected fixture succeeded. A fresh search tab worked; clicking a result stayed on search, and direct URL entry returned to the selected allowed page.
- After finishing through the app's End control, all five original tab IDs returned to their exact original window IDs and indices (zero differences). The fresh search tab remained at the end. Browser inventory confirmed no holding page remained. Temporary test tabs were closed afterward.
- Synthetic Shift-backtick did not reach the global shortcut, so ending via physical hotkey and its focus preservation are not claimed as live passes.

## Outstanding acceptance / release limits

- Chrome live hide/search/restore verification is complete for the controlled normal-profile session above; this does not cover every browser profile, private window, or crash scenario.
- Synthetic CUA global backticks were not reliably delivered to the macOS event tap. Physical double-tap group marking, held-prefix modifier combinations and full hide/show require physical acceptance; deterministic state-machine tests passed.
- A split-view pair with only one side allowed cannot safely move one member without affecting its partner. It stays guarded in place; select both members together. If native group metadata cannot be read, group tabs stay guarded in place rather than destroying the group.
- Browser crash/restart and disappearing source-window scenarios have simulated recovery coverage, not an exhaustive live matrix. Chrome restart recovery reveals preserved parked tabs; original placement cannot always be reconstructed from session-scoped IDs.
- No public extension release or update-feed change was made. This is not a declaration that every use case is bug-free or ready for ten testers.

## Waitlist: separate, unpublished preview

Workspace: /Users/loganmondi/Documents/Codex/intent-waitlist
Preview: http://localhost:5173/

The rejected redesign was replaced with the original moving mixed-font word wall and centered identity. Foreground text/form have measured clear space so moving letters do not overlap them, without a fade/blur backdrop. Occasional messages such as wewilltakebacktechnology replace the wall for 700 ms, then return; reduced-motion and pause are supported. The user's editable bottom copy and signup/email backend are preserved.

Website build and lint passed. Desktop 1440, phone 390 and narrow 320 were checked without horizontal overflow; extra-info navigation and pause were checked. A live sampled burst returned to normal without layout movement. Local preview only: no website commit, push, deployment, publication or signup email.

## Product recommendations (not silently implemented)

- Use Ctrl+Tab for switching among the intention's allowed tabs, Shift to reverse, and release Ctrl to select; the repository already includes an allowed-tab switcher. Avoid introducing another backtick chord for this.
- A text-entry-aware plain backtick is worth offering as an option, with a reliable modified shortcut available everywhere. Do not silently make Intent unreachable whenever focus happens to remain in an editor; accessibility detection is imperfect across apps.
