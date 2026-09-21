# Overview app pointer selection

## Report and reproduction

Logan confirmed that physical double-backtick mark/unmark now works, including removal of the outline and staged modifier bar on the second tested Chrome QA tab. He then reported that clicking apps in the overview did not allow them.

On `package-buBsUPCq` (PID 21890), pointer activation of the Spotify preview left it unselected and Run disabled. AX activation of its button selected it and enabled Run; a second AX activation deselected it. Pointer activation of the Timer control worked and opened its editor. This isolates a pointer hit-target/layering failure from the underlying selection mutation. The icon/name caption was also only an image/text group, not an actionable target.

## Scoped fix

`QuickSelectionView.swift` now places header and footer in separate bounded regions instead of a full-height control VStack above the previews. Wallpaper and tint explicitly ignore hit testing. Each icon/name caption is a real button invoking the same selection action as its preview. The separate browser tab-list button is retained; browser clicks still open tab selection rather than automatically allowing the entire browser.

No shortcut, tab identity, enforcement or selection-state code changed. No daily app or personal browser profile is replaced.

## Verification

- Existing release `IntentCoreSpec` executable passed, including app/tab selection, gestures, onboarding and 1–50-window layout checks (`/tmp/intent-app-click-core.log`). Core sources did not change in this patch.
- Release QA build and pointer acceptance: pending below.

## First candidate was insufficient

`package-EvbSwKCb` built successfully in 191.63 seconds and passed deep/strict signature verification. Its QA-only recording and Accessibility entries were refreshed through System Settings, followed by a verified no-process checkpoint and exact relaunch. However, pointer clicks on the Spotify preview/caption still did not select it. This candidate is **not accepted**.

Further inspection identified interaction modifiers placed after `.position`, whose wrapper occupies the whole layout proposal. A second patch moves hover, help, opacity and hit-testing modifiers before positioning so they are scoped to the card bounds, with the positioning wrapper last. Live verification of this second candidate follows below; the initial patch alone must not be reported as a successful fix.

## Accepted pointer fix

The final candidate `package-Ff4muflo/Intent QA.app` built successfully in 170.17 seconds (`/tmp/intent-app-click-build2.log`) and passed deep/strict codesign verification. Existing QA Accessibility and Screen Recording entries were replaced through supported System Settings controls with this exact artifact while QA was stopped. Sole PID 92675 launched afterward; readiness reports trusted=true, ready=true, Carbon fallback=false.

Live pointer checks on this candidate:

- The same Spotify preview point that failed before now selects Spotify and enables Run. Clicking its caption deselects it and disables Run when no other targets exist.
- QuickTime's preview and TextEdit's caption both select their apps. A real screenshot showed their green borders.
- Three additional consecutive Spotify preview-select/caption-deselect cycles passed, preserving the independent QuickTime and TextEdit selections on every cycle.
- A fresh overview accepted both app selections again. Switching to Block preserved the selections and displayed red borders. A one-minute Timer was configured and Run entered Quick Block at 01:00. Safety Stop was verified before this run and released it afterward. This proves the selection-to-run UI handoff; it is not a new physical blocked-input or composited blur certification.
- A pointer click on the Chrome QA preview opened its tab drawer with Select all unchecked and Run disabled, preserving the explicit-tab workflow rather than silently allowing all tabs. Closing the drawer restored the full layout.

The code-level cause was interaction modifiers scoped to the full-canvas `.position` wrapper. Moving them onto the bounded card made the failing pointer test pass. The explicit caption button and separated header/footer remain as bounded-target improvements.

The corrected overview is left open with no selection and no active intention. Daily intentions/schedules/cooldowns hashes match baseline and QA browser rules are inactive. No daily-app replacement, push or release occurred. The broader Firefox/physical blur/Spaces matrix remains open; three pointer cycles are not three integrated application acceptance passes.
