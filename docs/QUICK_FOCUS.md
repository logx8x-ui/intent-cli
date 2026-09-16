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

The compact Session popover combines a Timer (typed duration or Start/End clock time), an in-session task checklist, browser searches, and cooldown. Removed pre-start options are not offered in this picker. Checklists start unchecked, and the last completed task ends the session. During a session **`** toggles the draggable timer/checklist panel. The picker keeps a clock at the top right and uses a green Allow/red Block perimeter.

### September 16 verification

IntentCoreSpec, Chrome/Firefox behavior suites, browser idle-work checks, release readiness, and the optimized app build passed. Installed the development build without changing saved intentions. Native UI checks confirmed the compact picker/clock, named fallback app cards, both browsers' window/tab selection, deselect/reselect window highlighting, typed timer duration, End time's Start/End editor, Return starting a safe TextEdit-only blacklist session, and checking the final task ending that session without a save dialog. Test sessions were closed.

Automation did not establish physical delivery of global backtick, Shift-backtick, or Command-Shift-backtick, nor live hover-preview placement or panel dragging. These remain physical acceptance checks. Firefox's active tab connection worked, but its permanent installed extension was still 0.2.5 (required 0.2.9), so persistence after Firefox restart is not verified.
