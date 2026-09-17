# Quick Focus

Press <kbd>`</kbd> while Intent is running to open a full-screen overview of running apps. Click an app card to select it. A browser card selects all supported tabs in that window; its Tabs button opens a readable wrapping grid beside the overview. Hover previews replace that browser card, never the screen center. Press **Return** to run. **Escape** or **`** closes without starting.

Selecting a browser selects its currently open HTTP/HTTPS tabs. Deselect individual tabs in the tab grid to narrow it down. Selecting a single tab also selects its browser. Browser settings, extension pages, local files, and empty new-tab pages are visible but cannot be selected. Other browser engines are not supported by Browser Guard.

Quick Focus requires Browser Guard **0.2.6** and its matching native host for tab discovery and selected-tab enforcement. An older or disconnected guard produces an explanation instead of starting a broader session. Discovery is requested only while the picker is open; idle browsing retains event-driven, debounced snapshot behavior.

The overview is Intent's own window, using public macOS APIs; it does not alter the system Mission Control. The permission guide checks Accessibility and Screen Recording before opening the picker. On macOS 14 or newer, Screen Recording enables window previews; a capture failure falls back to named app cards. Hidden/minimized windows and apps without capturable windows retain their icons. Previews are held in memory and released when the picker closes. Tabs wrap into columns; very large tab collections scroll vertically rather than shrinking every tab. Apps without capturable windows appear as full icon/name cards in the main overview.

During the temporary session, Browser Guard restricts tab IDs separately for each browser as well as applying the selected website rules. Existing unselected tabs are preserved. If a browser loses all its selected tabs, Intent ends the temporary session. New tabs are not automatically included. An already-running intention or Zero Drift cannot be replaced through this picker.

Finish normally with **~ (Shift-backtick)** to return to the desktop without saving. **Command-Shift-backtick** finishes and saves the complete selection to the dashboard. Saving stores apps and website resources, not transient browser tab IDs; future runs use normal saved-intention website rules. Quick Focus selections are not expanded by Always Allowed presets. The picker does not open duplicate tabs or save an intention before you choose to save.

The bare <kbd>`</kbd> key is reserved while Intent is running. If another application has registered that global shortcut, Intent reports its unavailability in the menu-bar warning. Intent's settings reject assigning <kbd>`</kbd> to its other shortcuts. **Command-G** opens or hides Intent globally.

## Verification

Automated regression cases cover browser-specific tab identity, duplicate URLs, implicit browser selection, privileged-page exclusion, closed/disconnected resources, selection-only persistence, no duplicate startup resources, rules renewal, and preserving unselected tabs. Native-host tests verify forwarding tab IDs. Browser idle-work tests continue to check that idle events do not enumerate tabs.

Physical acceptance still requires the installed matching app, native host and both extensions: opening with <kbd>`</kbd>; selecting/deselecting across browsers; cancellation; app enforcement across Spaces; allowed-tab switching; finishing and saving/discarding; and visual layout on the user's displays. A release build alone does not establish these results.

## Session controls

The bottom modification strip exposes Timer (typed duration or Start/End clock time), Checklist, Searches and Cooldown as individual controls with hover help and enabled indicators. Removed pre-start options are not offered in this picker. Checklists start unchecked, and the last completed task ends the session. During a session **`** toggles the draggable timer/checklist panel. The picker keeps a clock at the top right and uses a green Allow/red Block perimeter.

### September 16 verification

IntentCoreSpec, Chrome/Firefox behavior suites, browser idle-work checks, release readiness, and the optimized app build passed. Installed the development build without changing saved intentions. Native UI checks confirmed the compact picker/clock, named fallback app cards, both browsers' window/tab selection, deselect/reselect window highlighting, typed timer duration, End time's Start/End editor, Return starting a safe TextEdit-only blacklist session, and checking the final task ending that session without a save dialog. Test sessions were closed.

Automation did not establish physical delivery of global backtick, Shift-backtick, or Command-Shift-backtick, nor live hover-preview placement or panel dragging. These remain physical acceptance checks. Firefox's active tab connection worked, but its permanent installed extension was still 0.2.5 (required 0.2.9), so persistence after Firefox restart is not verified.

## September 17: tab list and quick workspace marking

- Click a browser card to inspect its ordered vertical tab list; this does not select its tabs. Select all is an explicit checkbox, with **X** while the tab panel is focused (text editing is excluded). Hover previews appear below the list.
- **Modifications** sits at bottom-left, with hover help. Timer offers Duration and **Set end time**. The centered Intent wordmark uses a grave accent above the dotless i.
- Single **`** opens/closes the picker (or toggles session controls during a run), after a 280 ms double-press window. Double **`** toggles the foreground website tab or native window in a temporary workspace.
- Hold **`** and press **Return** to start that workspace; hold **`** and press **/** to change Allow/Block. In the picker, Return and / alone retain their existing behavior. **~** ends, **⌘⇧`** ends and saves.
- Native window marks are scoped to WindowServer IDs for this session. They are not persisted as stale IDs in saved intentions. A closed marked window ends its active session safely.
- Outline panels are mouse-transparent. The desktop shows the focused marked window; native Mission Control maps all unambiguous marked window titles to Dock tiles. Duplicate titles are intentionally not guessed. Browser window outlines follow whether the currently active tab is marked.
- Blur captures the mapped regions in one frame, retains blurred pixels during geometry refresh, and independently expires incompletely scanned AX rows. Context switches clear old overlays. Click enforcement remains separate from the visual cache.

Automated regression coverage includes single/double/chord dispatch, held-key repeat, key-up consumption, finish-shortcut pass-through, exact native-window allow/block scope, and partial Firefox/Chrome blur-region continuity. Native gesture delivery and trackpad transitions require live acceptance separately from these deterministic tests.

September 17 verification: optimized app/CLI/native-host builds and data-preserving development installation passed; CoreSpec (including the new gesture/window/partial-scan cases), Firefox/Chrome extension suites and release-readiness checks passed. Live UI checks verified browser click does not auto-select, X select/clear, Firefox list scrolling, actual Chrome and Firefox previews below the list, bottom-left Modifications and Set end time. A one-minute selected-browser session started with Return and ended on schedule; active browser rules were false afterward, with no saved QA intention. Chrome mapped five forbidden tab regions during that session.

Physical double-backtick/chord delivery, native Mission Control borders and trackpad-swipe blur continuity remain unverified: the automation's generated keys reached the browser field rather than the global input tap. Per-window screenshots also do not establish the appearance of other applications' overlay panels. The existing permanent Firefox extension is still 0.2.5; a connected temporary 0.2.8 guard supported this session's tab/preview checks, but restart-persistent extension updating still requires the matching signed XPI. These are limitations, not passed tests.

Quick-mark freshness follow-up: idle Browser Guard does not continuously publish tab snapshots. Marking and starting now request a new snapshot and wait for a timestamp newer than that request; marking also verifies the foreground window/title did not change while waiting. Mark operations are serialized, Start waits for the last mark, and staged borders request snapshots only while the workspace is being assembled. This prevents selecting the previously active tab from an idle snapshot.
The native host now renews snapshot timestamps for explicit discovery replies even when tab contents are unchanged; unsolicited duplicate snapshots still coalesce. `test-native-host-snapshot-refresh.cjs` exercises this handshake independently for Firefox and Chrome in temporary test directories and is included in `npm run test:native-host`.
Live installed-bridge verification also passed: explicit idle discovery responded in 0.261 s on Firefox and 0.213 s on Chrome; a second request in each browser renewed the snapshot timestamp while the tab payload remained identical. This is bridge evidence, not physical double-press evidence.
Final freshness build/install and signature/UUID verification passed. The native-host freshness, behavior and performance tests passed (8.0 MiB peak RSS); one earlier stress run exceeded its timed-write count while background-throttled during compilation, then passed unchanged after the build finished. No performance threshold was relaxed.

## September 17 follow-up: tab identity and preview recovery

- Staged browser marks outline actual native tab chrome or visible Firefox sidebar rows. Only native-window marks outline entire windows. Mission Control scales tab rectangles into uniquely matched window thumbnails; ambiguous titles are not guessed. Bounded partial-scan continuity avoids dropping valid outlines when AX runs out of time.
- Hold backtick and press Escape to clear all staged tabs/windows, including queued marks. This does not stop an active intention. The double-backtick mapping is unchanged pending the shortcut decision.
- Selected-tab sessions permit navigation, redirects and SPA channel changes within those exact tab IDs. Unselected tabs remain blocked, even with identical URLs. Saved website-based intentions retain their URL rules.
- Previews now try off-screen named windows, reject transparent captures, retry failed captures, and reuse a matching in-memory capture where available. Real window names remain visible when macOS cannot supply pixels. Apps with no capturable window still have a named app card; no fabricated preview is shown.
- Timer, Checklist, Searches and Cooldown are spread along the bottom. Each has its own editor, hover explanation and enabled indicator; the tab panel ends above this strip.

Verification: CoreSpec, both complete extension suites, idle-work checks, release readiness, extension lint (zero errors/warnings), extension packaging, optimized development installation and signature/installed UUID checks passed. Browser Guard 0.2.10 was reloaded in both browsers. Live selected-tab sessions allowed example.com to example.org navigation in both browsers, and switching Discord channels in Firefox without reversal. The original Discord channel was restored, disposable tabs closed, and the test intention ended without saving (active rules false). Live picker screenshots now show real Preview, Reminders, Music, Spotify, RStudio, Firefox, Chrome, ChatGPT and Finder windows; windowless QuickTime/TextEdit remain named cards. Timer editor and visible bottom strip were verified.

Physical global gestures and native Mission Control tab-outline alignment remain unverified: generated double-backtick did not stage a selection in this automation environment. Firefox's running 0.2.10 copy remains temporary; permanent 0.2.5 is outdated, and Mozilla signing credentials are unavailable for a persistent update. No claim of restart persistence or universal OS-protected preview availability is made.
