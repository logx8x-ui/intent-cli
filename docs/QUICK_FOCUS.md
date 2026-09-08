# Quick Focus

Press **Command-G** while Intent is running to open a full-screen overview of running apps. Chrome and Firefox tabs appear across the very top. Click an app or tab to toggle its green outline, then press **Command-G** again (or click **Start intention**) to run only the selection. **Escape** cancels without starting anything.

Selecting a browser selects its currently open HTTP/HTTPS tabs. Deselect individual tabs in the top strip to narrow it down. Selecting a single tab also selects its browser. Browser settings, extension pages, local files, and empty new-tab pages are visible but cannot be selected. Other browser engines are not supported by Browser Guard.

Quick Focus requires Browser Guard **0.2.6** and its matching native host for tab discovery and selected-tab enforcement. An older or disconnected guard produces an explanation instead of starting a broader session. Discovery is requested only while the picker is open; idle browsing retains event-driven, debounced snapshot behavior.

The overview is Intent's own window, using public macOS APIs; it does not alter the system Mission Control. App icons work without Screen Recording permission. On macOS 14 or newer, granting that permission enables a window preview for each app. Hidden/minimized windows and apps without capturable windows retain their icons. Previews are held in memory and released when the picker closes. With exceptionally many apps, the grid scrolls instead of making targets unusably small.

During the temporary session, Browser Guard restricts tab IDs separately for each browser as well as applying the selected website rules. Existing unselected tabs are preserved. If a browser loses all its selected tabs, Intent ends the temporary session. New tabs are not automatically included. An already-running intention or Zero Drift cannot be replaced through this picker.

Finish with your configured finish shortcut (default **Command-Shift-M**). Intent offers to save or discard the complete selection. Saving stores apps and website resources, not transient browser tab IDs; future runs use normal saved-intention website rules. Quick Focus selections are not expanded by Always Allowed presets. The picker does not open duplicate tabs or save an intention before you choose to save.

Command-G is reserved while Intent is running and therefore replaces apps' usual Find Next shortcut. If another application has registered that global shortcut, Intent reports its unavailability in the menu-bar warning. Intent's settings reject assigning Command-G to its other shortcuts.

## Verification

Automated regression cases cover browser-specific tab identity, duplicate URLs, implicit browser selection, privileged-page exclusion, closed/disconnected resources, selection-only persistence, no duplicate startup resources, rules renewal, and preserving unselected tabs. Native-host tests verify forwarding tab IDs. Browser idle-work tests continue to check that idle events do not enumerate tabs.

Physical acceptance still requires the installed matching app, native host and both extensions: opening with Command-G; selecting/deselecting across browsers; cancellation; app enforcement across Spaces; allowed-tab switching; finishing and saving/discarding; and visual layout on the user's displays. A release build alone does not establish these results.
