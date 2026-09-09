# Intent field of view — September 9, 2026

## Implementation

Replaces the Quick Focus app-card grid with a borderless wallpaper-backed window overview. The top strip reads `intent field of view`. Capturable windows retain their aspect ratios and animate from global desktop positions into an overview, then back on Cancel/Start. Reduce Motion skips those transitions.

Each window is captured independently with ScreenCaptureKit, capped at 1,000 pixels on its longest edge. No window is moved, hidden, or closed to lay out the overview. Preview images are memory-only and discarded on close. Apps without a capturable window appear in a small bottom row. Capture errors are explicit placeholders, not invented window contents.

Non-browser selection remains **app-level**: every displayed window belonging to a selected app turns green. This patch does not introduce exact-window enforcement. Clicking a Chrome/Firefox window selects only the selectable tabs belonging to that browser window. Individual tab bubbles extend above their window, scroll within its width, and retain green selections. Partial browser selections highlight the selected tabs, not the entire window.

Native window IDs and browser-extension window IDs are different namespaces. Matching uses unique active-tab titles (or an unambiguous single-window case), with a one-to-one check. Duplicate/unknown titles do not guess: the UI explains how to reconnect or disambiguate. Existing Browser Guard selected-tab enforcement is reused. No extension permission changes or private Dock APIs are introduced.

Second Cmd+G validates and starts; Escape cancels. Start is disabled while capturing or with an empty selection. Enforcement starts after the closing animation. Existing finish/save behavior is retained.

## Automated checks

- IntentCoreSpec passed: 1, 2, 4, 9, 16, 30, and 50 windows fit within the display, preserve aspect ratios, and reserve non-overlapping tab/caption regions.
- Browser-window matching and selection tests passed: selecting/deselecting one window does not broaden or erase another window's selected tabs. Truncated native titles match unique prefix/suffix pairs; duplicate active titles are rejected.
- Chrome/Firefox extension rule, background, and performance regression tests passed.
- Debug IntentApp build passed.

## Installed checks

- Production app/CLI/native-host builds passed; `scripts/install-dev.sh` installed and relaunched the development build with user data preserved.
- Installed Intent already had capture access. No Screen Recording or other privacy permission was changed during QA.
- Cmd+G opened the correctly titled overview and captured real windows. Inspection caught invisible helper windows; the capture inventory now excludes tiny/untitled helper surfaces, with affected apps still available in the bottom app row.
- Coordinate-clicked Notes, confirmed its persistent green outline and hover label, then verified Escape returned without starting a session.
- Chrome tab bubbles appeared directly above the correct browser window. Horizontal scrolling stayed within that window's width. Coordinate-clicked a tab and visually verified the green bubble.
- Selected Notes plus one Chrome tab, pressed Cmd+G again, and inspected active Browser Guard rules: exactly one selected Chrome tab ID, with no startup website launches.
- File → Finish Intention presented Save with two apps and one website. Discarded only this temporary QA candidate; browser rules were inactive afterward.
- System Settings → Wallpaper displayed `MissingImage` for the current wallpaper and its original file is absent. A filtered display capture successfully recovered the beach wallpaper still cached by macOS. Final visual inspection confirmed the backdrop excludes desktop icons and widgets. No wallpaper setting was changed; independently capturing a background-layer window was black/transparent and is not used.
- Opened a temporary second Chrome window at example.com. Both Chrome windows displayed their own tab strips, including the original window whose native title was truncated. Clicking the new window selected exactly its one tab; second Cmd+G produced exactly that tab ID in active rules. Finish offered Save for one app and one website. Discarded the QA candidate and closed only the temporary window.
- Installed app passed strict code-signature verification. The installed and production-built executable UUIDs match (signing changes the raw binary bytes).

## Live acceptance boundary

Actual capture requires macOS Screen Recording permission. Existing access sufficed for the installed checks above. Opening and settled overview states were observed, but animation smoothness was not benchmarked against native Mission Control.

Remaining cases: multiple monitors, an explicit cross-desktop/minimized-window matrix, and duplicate live active-tab titles. Matching/selection ambiguity has deterministic tests, not full physical acceptance. Protected content can be unavailable to capture. Firefox reports Browser Guard 0.2.5 without the selected-tab capability, so its tab strip remains unavailable on this Mac; this UI-only patch does not resolve that extension installation limitation. In-app Cmd+G passed; physical global key delivery outside Intent was not independently measured.
