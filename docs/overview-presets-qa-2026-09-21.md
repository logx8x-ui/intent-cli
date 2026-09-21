# Overview browser mapping and app defaults

## Scope

Browser cards open their own vertical tab list. Matching uses active titles first and geometry for duplicate-title ties, rather than assigning every same-size native window to one Browser Guard window. A disconnected profile never borrows another profile's tabs. The manual window picker is removed; missing bridge data provides a refresh action.

A bottom-right cog opens local settings: clock, title labels, and searchable, mutually exclusive Always allowed / Always blocked app lists. Finder and System Settings are first-install defaults; the untouched old Finder default receives a one-time upgrade, while empty and customized lists are preserved. Both lists appear in a compact bottom-left strip and are excluded from the preview grid. Packing retains a common native-window scale and expands the remaining windows into the freed space.

Session creation resolves both lists for Quick Focus and saved intentions in either mode. Whole-browser presets override selected-tab scope. Always-allowed browsers are exempt from host rules and native tab guards; always-blocked apps are not terminated on launch. Safety Stop remains unchanged. Changes stay in the isolated QA build and data root.

## Automated verification

Release app build passed (408.96s, `/tmp/intent-presets-package-build.log`). The final CoreSpec rebuild passed (271.07s), followed by all core specs, including 100 gesture sequences, preset policy, and 1–50-window layout checks (`/tmp/intent-presets-final-spec.log`). Firefox/Chrome extension tests passed; native host exemption and snapshot freshness checks passed. Deep/strict signing verification passed. These checks do not prove physical browser input or Spaces animation.

## Live verification

Candidate: `/Users/loganmondi/.codex/artifacts/intent-qa/package-zfGeTf7y/Intent QA.app`, sole PID 31963. Existing QA recording and Accessibility entries were refreshed through System Settings while QA was stopped. Effective readiness reports trusted=true, ready=true, Carbon fallback=false.

- Real screenshots show a centered header, scaled mixed-size windows, the bottom-left preset strip and bottom-right cog; Finder and System Settings no longer occupy grid cards.
- Pointer-clicking Chrome QA window A opened its two tabs (Notes and Extensions), with Select all off. Selecting Notes enabled Run. Clicking window B directly opened its own original seven-tab list; Select all selected B without selecting Extensions in A. Returning to A retained only its selected Notes tab. Both lists were then cleared.
- The cog opened the editable settings popover. Adding Spotify to Block removed its grid card and added its red preset icon. Moving it to Allow removed it from Block; removing it restored its grid card. Removing the System Settings default restored its window; adding it back hid it. Clock toggle removed/restored the live clock. Escape closed only the settings popover.
- A one-minute Block session started with Calculator selected and Spotify in the blocked presets. Safety Stop was verified before and after, and the session was released early. Spotify's original process remained running. This proves the UI-to-session handoff, not new physical blocked-click or blur certification.
- A fresh overview retained the temporary preset; it was removed afterward. Final state is Finder + System Settings allowed, no blocked presets, clock on, no selected targets, no active rules. A final pointer test selected Spotify with a visible green border and deselected it through its caption.

Temporary Chrome QA assets had been removed by macOS temporary-file cleanup; missing icons/rule/popup files were restored from the repository with fresh timestamps, retaining the QA host binding. The QA host wrapper now uses `IntentNativeHostQA-presets`; no personal profile host or extension was changed. The local fixture server on 18765 and extra QA window remain available for follow-up testing.

Daily intentions/schedules/cooldowns hashes match the current-turn baseline. No daily-app replacement, push or release occurred. Firefox live UI, physical Spaces/input checks, and indistinguishable same-title/same-geometry windows remain outside this acceptance pass; ambiguous matches still fail safely instead of choosing another window's tabs.
