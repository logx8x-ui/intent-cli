# Tab click prevention and Space recovery

## Scope

- Preserve the existing Mission Control tile-click policy.
- Reject identifiable forbidden native browser-tab mouse-down events before activation, instead of relying solely on extension bounce-back.
- Restore the actual last permitted window when a forbidden window becomes visible after a Space change, including stale foreground-app reporting.

## Implementation

The native tab guard builds short-lived AX tab rectangles on a dedicated queue with a bounded scan and short AX timeouts. The event tap only checks cached rectangles. Native tab counts/order must match complete extension metadata before indices are trusted; webpage/ARIA tabs are excluded. An incomplete or stale map falls back to Browser Guard's existing enforcement, rather than freezing input or guessing. Dragging temporarily invalidates geometry. Extension move/attach/detach events refresh ordering.

Browser snapshots keep permitted switcher entries separate from the complete metadata used for native hit-testing. Identical titles/URLs therefore do not make separate tab IDs interchangeable. Leisure does not install this guard.

Space recovery no longer waits 1.1 seconds for a single foreground-app check. It examines the visible window owner and restores a remembered AX window using main/raise/activation, with bounded short retries. The focus timer also detects a visible forbidden owner while NSWorkspace still reports the old permitted app. Mission Control retains its separate click path and is excluded from the new Space restoration policy. No reverse gesture is synthesized and no private Spaces API is introduced.

Local diagnostic files contain counts only: native swallowed clicks/regions, Space-change notifications, restoration requests, and verified returns to the remembered window. They contain no titles, URLs, images, or click positions; writes occur outside the input callback and its mutex.

## Automated checks

- IntentCoreSpec passes: exact native tab-ID/order mapping including duplicate titles/URLs, refusing incomplete native lists, visible forbidden/allowed windows, Mission Control exclusion, and blacklist empty-desktop behavior.
- Chrome/Firefox background/rule and browser idle-work tests pass.
- Native-host protocol and performance tests pass; full metadata remains separate from allowed switcher tabs.
- Chrome and Firefox 0.2.8 archives build; Firefox lint has zero errors, warnings, or notices.

## Installed acceptance

- Development app installed and relaunched; signature verification passes. Chrome 0.2.8 is loaded. Firefox is still running 0.2.5, so matching Firefox runtime acceptance is outstanding.
- Two selected Chrome tabs produced two permitted entries, seven full-metadata entries, and five forbidden native regions. A one-tab session produced six forbidden regions. Allowed-tab activation worked.
- Automated coordinate clicks produced zero native mouse-down events (and zero Mission Control events or swallowed clicks). These automation actions cannot prove the native pre-activation veto works; a physical forbidden-tab click remains required.
- Automated Control-arrow shortcuts produced no Space-change notifications. An actual temporary TextEdit fullscreen transition produced two notifications and seven restoration requests, but zero verified exact-window returns. Physical swipe recovery is therefore NOT acceptance-passed.
- The empty QA document/fullscreen Space was closed. All temporary intentions were finished and discarded; user intentions and browser tabs were preserved.

Physical three-finger swipes must not be inferred from keyboard Space navigation, restoration attempts, or policy tests. Both physical-input acceptance items remain open.
