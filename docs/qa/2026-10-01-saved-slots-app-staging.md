# Saved slot interaction and app staging — October 1, 2026

## Result

- Removed the filled caption capsule behind window names; titles remain white.
- Saved slots use the same local drag gesture as modifications, including a 0.4-second reorder animation and Reduce Motion support.
- Each slot has a top-right X. Deletion preserves history, normalizes visible numbers, supports model undo, and rolls back on persistence failure.
- Saved number requests are retained while previews load by intention ID. Closing the overview, changing the draft, deleting the requested slot or superseding the request prevents stale starts.
- App selections release the optional name field's keyboard focus, so subsequent numbers act as shortcuts after clicking an app.
- New Spotlight and closed saved-app additions have removable icon cards. Closed native apps are staged without launching processes, then opened by the existing startup planner only after Start. X cancels the staged launch; already-running user apps are not terminated.
- Reopening a fully closed native app prepares its default workspace. Existing native windows and browser tabs retain exact replay rules: missing/ambiguous browser tabs still require review rather than granting a whole browser silently.
- Removed the unreliable background-opening toggle and warning. NSWorkspace background launch hints cannot guarantee that third-party apps will not activate themselves. Staging avoids this class of foreground flash entirely.
- Empty old blacklist slots now explain that no target is recorded instead of silently doing nothing. In Logan's data, “gram” and “imessage block” were already empty before these edits; their targets were not guessed or overwritten.

## Verification

- IntentCoreSpec passed, including all 1–9 saved-key mappings, text input protection and held-backtick modifier routing.
- Release IntentApp build passed.
- Actual isolated app-model checks: 38 assertions passed. Covers staging without process creation/activation, closed/scoped native-app replay, pending startup policy, app removal, blacklist startup suppression, deletion/undo/renumbering, history retention and disk-failure rollback.
- Development app installed using scripts/install-dev.sh with matching embedded browser/helper sources.
- Source/installed executable UUID: 307EA465-177D-3ADD-A833-0B79F2AFA0B0. Deep strict code signature verification passed. Accessibility and gesture tap report ready.
- Live UI: captions visually verified without capsules; slot drag swapped positions 2/3 and reversed cleanly without starting a session.
- Live UI: saved/deleted a disposable existing QA-history slot with X; history remained and bookmark returned to unfilled.
- Live UI: created a fresh “QA saved blocker slot fix” blocking Spotify, ran and saved it, then pressed 9 to auto-run it. Active controls and journal confirmed blacklist start. Finished and deleted the disposable saved slot; original eight saved slots/order retained.
- Live UI: clicking a Spotify preview leaves the window, not the name editor, as keyboard focus; test draft cleared afterward.

## Remaining acceptance

- Apple's actual Spotlight opens from Intent's footer; selected Calculator application cell and native-search-ready diagnostic observed. Physical Return check is pending: computer-use app-targeted Return bypasses the global keyboard tap and launches Apple's result normally. This is not evidence of the physical-key interception passing or failing. Calculator from that automation attempt was closed; no test session remains active.
- A physical-key request is prepared on Logan's screen; after Return, verify removable icon, no Calculator process until Start, X cancellation, then a whitelist run and saved closed-app replay.
- Existing unrelated distribution gap: installed permanent Firefox add-on is 0.2.20, while bundled/matching build is 0.2.22. Temporary add-ons/heartbeats do not prove a permanent signed update survives browser restart. No extension behavior changed in this patch.
- This report does not claim exhaustive, zero-bug or browser-store acceptance.
