# October 5: DBT controls, timer recall, picker dismissal and completion laser

## Reported sequence and causes

- After selecting tabs, backtick plus physically held Caps Lock must Run in either order. The overview consumed backtick and reset the global gesture, while the event monitor sent Caps flags only to that reset global gesture. The overview also dropped physical-Caps information entirely.
- Backtick plus a modification number must toggle that displayed slot, including unnamed intentions. The controller's numbered entry point incorrectly required the optional name.
- A modifier editor opening during a held chord must not steal the chord; starting a new backtick while deliberately typing must remain text. Consumed number releases remain owned even if the prefix is released first or modifier flags change.
- Clicking a non-browser must dismiss the browser picker without dropping its already-selected tabs. The old window/app handlers only changed selection and left picker state and resolution work active.
- New timers must reuse the last explicitly entered duration. Creation hard-coded 25; saved timers retain their own duration, including the legacy nil-value meaning of 25.
- Completion remains a narrow finite mode-coloured edge effect, now with a 180-point core and 220-point halo rather than 76/112. Core opacity increases to .96 without widening its 1-point stroke. Lifetime remains 1.05 seconds.

## Ownership and safeguards

- Physical event normalization feeds one shared routing decision for key and Caps events; the overview receives physical-Caps state. No inout gesture access is held across a reentrant controller/modal callback.
- Picker dismissal invalidates its resolution identity before cancellation and clears preview state. A canceled task cannot set loading on its first queued actor turn or activate the old picker in defer. Snapshot reloads are owned and canceled too.
- Timer defaults are recorded only by explicit duration edits, not by opening saved intentions, cooldown edits or end-time edits. Existing saved values are never replaced by the preference.
- Completion retains exact shared whitelist/blacklist colour, the same path origins, nonactivating mouse-transparent panel, finite compositor animation and Reduce Motion behavior.

## Verification

- Final source-stable `npm run test:session-ui` passed: native event decoding/routing, isolated CoreSpec, release build, **110 app-model assertions** and **165 presentation assertions**. Evidence: `intent-session-checks-j7Tt7rbq` under the system temporary directory; source fingerprint `42a3ab4cb1148d35dc3f133e9256e593983c8d97aec6104fc0c5f2004bad8455`.
- An intermediate release compilation rejected the new test-injectable passcode callback without explicit actor isolation. The callback type is now `@MainActor`; the full gate was rerun after correction. That failed intermediate build was not installed.
- Both extension suites and the native-host suite passed, including profile coverage and performance (10.5 MiB peak RSS). No extension protocol/version bump or store publication was needed for these app-side changes.
- Installed via `scripts/install-dev.sh`. Daily app `/Users/loganmondi/Applications/Intent.app`, bundle `dev.loganmondi.intent`; installed app UUID `117D8266-0C2B-376E-9B16-BC98587E6BFD` matches the gated release/QA executable. Embedded native host UUID `F1D3515B-2BBB-30CF-AD91-3C71017F29F0`. Strict deep signature verification passed.
- Real overview: selected one Firefox tab, clicked Spotify, observed the entire picker disappear, then reopened Firefox and confirmed that exact tab remained selected. Deselecting the temporary tab choice left the user's tabs untouched.
- Real timer editor: changed 25 to 37 through its accessibility text control, closed/reopened the editor and observed 37; removed Timer, re-added it and observed 37 again. App-targeted typing did not reach the popover field, so it is not claimed as a typing-path pass.
- Native CUA rejects `grave+1` with `keyPressIncludedMultipleNonModifierKeys`. Hardware DBT, held backtick-number and Caps Run remain explicitly unverified; the native event fixtures exercise their production routing, but do not post physical input.
- Firefox's current default-profile connection reports development 0.2.34. Its underlying permanent signed package is still 0.2.28, with temporary 0.2.34 active; restart/store-update acceptance remains separate. Chrome's 0.2.34 heartbeat is stale and this pass makes no new live Chrome-profile claim.

## Installed timer expiry and cleanup

- Ran a disposable one-minute blacklist intention targeting Spotify only, named `QA DBT controls completion`. No browser target or selected tab was included. Started through the Run button, not a physical Caps chord.
- The session journal reports 60.031 seconds between start and timer completion. A passive window observer saw the compact HUD replaced by the screen-edge completion panel, which disappeared after approximately 1.040 seconds (the configured animation lifetime is 1.05 seconds). No Intent panel reappeared during the following 16-second observation.
- Browser rules were inactive and the hidden-workspace snapshot empty afterward. The app process stayed alive throughout. The observer did not send input or change focus. Intent was already frontmost before the test, so this proves expiry and panel cleanup, **not** preservation of a different user-facing app or Space.
- Restored the pre-test 25-minute duration using the installed editor, reopened it to confirm 25, removed the temporary timer draft and dismissed the empty overview. No QA restriction remains active; the completed, unsaved QA history row is retained as evidence.
- A final passive window-list read returned no Intent windows on screen while PID 56421 continued running from the installed app path. Calling the app-targeted accessibility observer after Close had reopened the overview; the final dismissal was checked passively instead.
- Passive observation evidence: `/tmp/intent-dbt-panel-observation.jsonl`; session `AD85A2FA-1C2D-4A9E-9468-2818090B81BF`. Temporary evidence paths are machine-local and not durable release artifacts.

The pre-existing browser-restoration foreground issue from the Head Chat checkpoint is not claimed fixed by this UI change. Physical held-key acceptance and permanent Firefox/restart acceptance remain separate from the passes above.
