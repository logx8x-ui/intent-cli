# Fresh overview, modifier editing and website discovery

## Acceptance brief

Logan's latest October 5 request supersedes the previous retained-draft rule:
plain backtick or Escape closes SBT and clears all selection/modifications;
DBT to SBT enters a fresh empty overview. Explicit saved/resume actions still
preload their own configuration. Caps Run and numbered modifiers remain
protected, separately from physical acceptance of this candidate.

Modifier bodies toggle. Timer/cooldown have a small hanging duration pill and
hours/minutes editor, with independent last-explicit-edit defaults. Saved
intentions retain their own values. Checklist clicks open/reopen a plain lined
editor: blank dismissal removes it, written lines remain, and its trash control
removes it. Fresh session/draft checklists are blank unless explicitly saved.

T in a selected browser's SBT picker opens a website finder in its preview.
It is an ephemeral WebKit/DuckDuckGo view, **not** Firefox/Chrome's signed-in
profile. Direct URLs and clicked search destinations are captured once; the
preview cancels destination navigation. A correlated Browser Guard command adds
one real background tab to the exact chosen profile/window and selects its real
receipt ID. Firefox can create discarded; Chrome loads that background tab.
There is no fallback to Launch Services, the current arbitrary browser, fake
tab IDs, activation or automatic retry after an uncertain effect.

## Owning changes and adjacent checks

- Controller cancellation invalidates queued marks and clears the full draft.
  One-shot saved/resume preloading is consumed on overview entry or successful
  start; it cannot leak into an unrelated later selection.
- Plain backtick still exits while editing. A consumed prefix chord release
  cannot also close the overview. T only triggers outside editing with a browser
  picker; its release is owned even after focus changes. Finder editing shields
  ordinary digits, Return, X and Space from overview commands.
- Valid duration text edits persist immediately, not only on Return or focus
  resignation. Bindings use node identity, preventing stale callbacks from
  mutating replacement restrictions. Checklist blank dismissal also runs on
  editor switches, Spotlight transitions and Run validation.
- Firefox AX window-root discovery unions listed/focused/main windows with
  identity deduplication and ambiguity/minimized guards. Separate evidence is
  recorded in `2026-10-05-firefox-dbt-history-followup.md`.
- Browser tab creation is capability-gated and requires matching 0.2.35
  development components. Older profiles keep their existing functionality;
  they must not be described as having tested the new creation feature.

## Verification

Final source-stable `npm run test:changed` passed all eight suites on October 5,
14:55:30–14:57:31 UTC. Evidence:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-zElW3t`.
Source fingerprint:
`1168940ef36b6202c1db20e87617e6d8acf3aea8d12da1271c6dca146b339bd7`.
The gate includes 196 isolated app-model assertions, 232 real-content render
assertions, native keyboard fixtures, core/browser/native-host/release/AI checks
and extension lint. Twelve compact modifier render variants passed, including
blank/written checklists, timer/end-time/24-hour duration, and cooldown in both
access modes. Final independent read-only review found no additional blocking
source defect. This is not a blanket release-readiness claim.

Installed using `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin scripts/install-dev.sh`.
The PATH override uses system Python because Homebrew Python's pyexpat failed
to load; no unrelated Python installation was changed. Daily app path:
`/Users/loganmondi/Applications/Intent.app`, bundle ID `dev.loganmondi.intent`.
Installed app UUID `D3B68AD5-95D4-3D87-A4E8-B5ABBB9BB357` and helper UUID
`6DED4F16-EA22-3888-8F95-09E0A8B25AFB` match release outputs. Deep strict signature
verification passed. Accessibility and gesture readiness were true.

### Installed live checks

- Before the final focus-only repair, timer body toggles, separate duration pill,
  immediate valid edit persistence, off/on persistence and fresh-overview default
  persistence passed through supported UI controls. The original 1-minute default
  was restored after testing. Numeric editing used AX setValue, not a physical
  typing acceptance claim.
- Blank checklist dismissal removed it; a written line remained after dismissal
  and reopening. Escape cleared selected app/modifier draft, and reopened overview
  had all modifiers off and Run disabled. Test checklist content was cleared.
- Chrome direct URL and a real DuckDuckGo result click each added exactly one real
  background tab in the chosen profile/window; destination did not open in the
  preview. Existing active browser tab and Intent foreground remained unchanged.
- Those checks caught a real T-autofocus bug: SwiftUI onAppear could leave typing
  in the optional intention-name field. Replaced with a native attached address
  field, guarded by current target, visible/key window, cancellation and lifetime.
  Eleven added attachment/focus regression cases passed in the final gate.
- On final installed UUID D3B68AD5, T focused the address field in both Chrome and
  Firefox. Ordinary typing (including digits) entered that field, and Return added
  a tab without starting an intention. Chrome produced one inactive tab in window
  1733680576; Firefox produced one inactive, discarded tab in browser window 11.
  Each original active tab stayed active. Intent remained foreground; rules stayed
  inactive. Real receipt IDs were selected in the overview.
- Switching from an open Firefox finder to Spotify removed both finder and tab
  picker, without a delayed focus callback. Escape then closed the overview.
- All tabs created by these checks, the temporary Chrome extension-manager tab,
  and temporary Finder windows were closed. Existing tabs, saved intentions,
  interrupted-session history and preferences were preserved.

Chrome's actual unpacked extension and Firefox's actual temporary ZIP both
reported version 0.2.35 and `background-tab-create-v1`. Firefox's loaded ZIP was
verified in about:debugging; this is **not** a permanent installation. The default
profile still has signed 0.2.28 underneath, and the QA profile has no permanent
extension. Matching Mozilla signing/install and restart acceptance remain open.

### Explicit remaining acceptance boundaries

Computer History and automated input do not prove physical DBT/Caps Lock or actual
green outline pixels. Two CUA grave events on Firefox did not produce a DBT panel;
that targeted synthetic path is not evidence of a physical event-tap failure or
pass. The focused/main AX-root correction is installed and regression-tested, but
actual foreground Firefox outline, physical chords, and start/finish exact-window
delayed-tail acceptance remain pending. No live intention was started by this
turn's finder/modifier checks.

GitHub workflow publication remains blocked: an ordinary push of the existing
local workflow commit was again rejected because the osxkeychain PAT lacks the
`workflow` scope. No credentials were read or replaced. The existing browser
connector cannot expand that credential's OAuth scope.
Firefox reached GitHub's mandatory two-factor checkup page for the signed-in
account. The code field was empty; no credential or recovery value was read,
entered or stored. The user must complete that verification before the narrow
workflow-scope repair can continue. No force push or credential deletion was used.
