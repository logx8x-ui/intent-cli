# Firefox tab interaction and session controls — 1 October 2026

## Change

- WindowServer resolves ordinary click ownership before accessibility hit testing; Dock/window-manager targets retain represented-app checks. Tab recovery in both extensions yields to newer allowed clicks and does not reactivate an already permitted foreground tab.
- Staged outlines scan less frequently, cache complete unchanged geometry, and avoid traversing background browser windows during normal browsing. These reduce work; perceived hardware latency still needs live acceptance.
- Add as you go keeps selected resources as its initial workspace, parks initial unselected tabs and hides initial unselected apps/windows once, then permits later additions. Explicit blacklist/preset bans retain priority. Chrome does not install an exact-tab network block in this mode. Initial tab visibility ownership survives a suspended extension worker.
- “Searches” is “Tab searches”; stored modifier order migrates without renumbering the user's arrangement.
- Modifier editors use a 300-point panel, smaller text/spacing, rounded thin material, and a subtle outline.
- The legacy finish-and-save sheet is deleted from both UI hosts and from its view implementation. Normal session completion only records history. Explicit finish-and-save still saves directly, without the old sheet or an unconditional overlay presentation.
- Double-tap selection runs with Caps Lock + backtick. Plain Mission Control Return remains. Backtick + Return no longer runs staged selections. Physical Caps Lock state is read separately from the latched capitalization flag. Both chord orders, repeat suppression, and running after modifier changes have deterministic regression coverage.

## Verification

- IntentCoreSpec passed, including 100 repeated gesture sequences and the new chord/order migration assertions.
- Firefox and Chrome extension suites passed, including a concurrent blocked-click/allowed-click regression that requires no synthetic reactivation of the allowed tab.
- Visibility tests passed, including initial Add as you go parking, future-tab preservation across worker suspension, and restoration without deleting user tabs.
- Isolated app persistence suite passed (32 assertions). This is model/render coverage, not live desktop acceptance.
- Release app build passed; development installation preserves the existing stable bundle identity and user data. Final source/installed executable UUID: `268DEBC8-3593-3668-BF14-D7A643F96000`. Deep/strict codesign verification passed; accessibility trust and the event tap both report ready.
- Native-host behavior, performance, profile-routing, and snapshot-freshness tests passed (observed peak RSS 8.3 MiB).
- Firefox lint: zero errors, warnings, notices. Firefox and Chrome 0.2.23 packages built.

## Live acceptance still pending

The Mac locked during browser update work. The computer-use tool reported it could not unlock it, and Logan was asked to unlock. Do not interpret the automated checks as proof of physical Caps Lock input, Firefox/Sidebery fluidity with modifiers, popup appearance, or finish-window focus.

The permanent Firefox extension is 0.2.20; 0.2.22 was running temporarily before this update. Matching 0.2.23 sources are installed by the development installer but must be loaded/reloaded in the actual browser profile and checked. Mozilla's authenticated developer portal is open. An earlier 0.2.23 archive was uploaded and validated; the final rebuilt archive includes a later new-browser visibility guard and must replace that upload before final submission. No permanent signature, installation, browser restart, or public update-feed publication is claimed.

Remaining live matrix: actual double-tap selection and rapid Firefox/Sidebery clicks; Caps Lock chord in both orders; Timer/Checklist popup and toggles; Add as you go initial visibility plus fresh app/window/tab/navigation and persistent bans; session finish without save sheet or foreground changes; Chrome equivalent tab policy; permanent Firefox installation/restart.
