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
- Native helper and both extension manifests advertise 0.2.19 consistently.

## Automated verification

- Full `npm test`: passed (core, purpose matching, account, Firefox/Chrome behavior, installation checks, idle workload, popup, tab visibility, native host, native host performance/freshness, 14 AI service tests, release readiness, Firefox lint).
- Quick gestures: 100 repeated sequences, including held-prefix number chains, retoggle and repeat-key handling.
- Layout: 1–50 windows.
- `scripts/test-modifier-toggles.sh`: all four disable/re-enable, independence, idempotence and end-time removal checks passed.
- Added regressions for old versus fresh search tabs, service-worker resume/new-session identity, holding pages initially reported as about:blank, silent move failures, Sidebar restore reordering, pinned/native groups, split pairs, lost source windows, persistence failures, and private/normal separation.
- Release app/native-host build and matching development install succeeded. Firefox lint: zero errors and warnings. Both extension packages built.
- Latest private-window change was checked with the visibility spec and extension lint/build after the full suite; it does not change native code.

## Installed and observed

Installed development app: ~/Applications/Intent.app, bundle dev.loganmondi.intent.

Native live checks:
- Preview appears in default allowed apps.
- Timer and Checklist open directly enabled, without the extra checkbox.
- Searches enables/disables directly without a popover.
- Three-minute timer plus two tasks: collapse, drag and expand worked. First checkbox left the intention running; second ended it early and cleared active rules and hidden-workspace state.

Firefox normal profile with Sidebery, signed 0.2.18 intermediate build:
- A controlled window containing one selected page, one unselected page and an old Google-results tab showed only the selected page during Hide mode.
- After the one-minute timer, all 24 pre-test tab IDs were still present in their original windows; no user tabs were lost.
- This live test exposed a leftover blank holding window and changed order for two returning test tabs. Both are fixed in 0.2.19 source with regressions. Final live retest is still pending the signed build below.

Chrome heartbeat reported 0.2.19 after the existing idle update mechanism ran. Final live browser verification is not yet complete; the latest private-window source addition also needs a reload before being exercised.

## Outstanding acceptance / release limits

- Firefox 0.2.19 package is ready at dist/firefox/intent_browser_guard-0.2.19.zip. The Mozilla upload file chooser is prepared, but native automation repeatedly reopens Go to Folder instead of accepting it. User handoff requested to press Return and Open. Final signing, install and live retest remain pending. Firefox currently reports 0.2.18.
- Chrome's extensions management page was blocked by browser automation URL policy. No alternate route to that page was used. The old reload handoff was superseded when the normal idle mechanism updated Chrome, but final live browser tests remain pending.
- Synthetic CUA global backticks were not reliably delivered to the macOS event tap. Physical double-tap group marking, held-prefix modifier combinations and full hide/show require physical acceptance; deterministic state-machine tests passed.
- Live drag/reorder then overview-close verification remains incomplete. Source teardown and modifier tests passed.
- A split-view pair with only one side allowed cannot safely move one member without affecting its partner. It stays guarded in place; select both members together. If native group metadata cannot be read, group tabs stay guarded in place rather than destroying the group.
- Browser crash/restart and disappearing source-window scenarios have simulated recovery coverage, not an exhaustive live matrix. Chrome restart recovery reveals preserved parked tabs; original placement cannot always be reconstructed from session-scoped IDs.
- No public extension release or update-feed change was made. This is not a declaration that every use case is bug-free or ready for ten testers.

## Waitlist: separate, unpublished preview

Workspace: /Users/loganmondi/Documents/Codex/intent-waitlist
Preview: http://localhost:5173/

Complete new visual direction: warm neutral background, indigo accent, large concise headline, rounded signup, interactive workspace showing distractions tucked away, name/choose/do explanation and timer/checklist section. Existing signup/email backend preserved.

Website production build and lint passed. Desktop 1440 and phone 390 layouts checked; phone horizontal overflow was zero. Focus-preview toggle checked both directions. No signup email was sent for this design-only QA. No website commit, push, deploy or publication was performed.

## Product recommendations (not silently implemented)

- Use Ctrl+Tab for switching among the intention's allowed tabs, Shift to reverse, and release Ctrl to select; the repository already includes an allowed-tab switcher. Avoid introducing another backtick chord for this.
- A text-entry-aware plain backtick is worth offering as an option, with a reliable modified shortcut available everywhere. Do not silently make Intent unreachable whenever focus happens to remain in an editor; accessibility detection is imperfect across apps.
