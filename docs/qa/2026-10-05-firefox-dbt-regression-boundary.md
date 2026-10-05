# Firefox DBT outlines and protected workflows — October 5, 2026

## Acceptance brief

Logan physically confirmed Caps Lock + backtick Run on `f969241` after several
runs. Do not convert that confirmation into a pass for a later binary. Backtick
number toggles are also protected. The reported failure is the green mark on
the **actual Firefox tab**, not a selected thumbnail in Intent's overview.

DBT Run must preserve its exact current native window and browser tab. Normal
completion must preserve the window/tab current **at completion**, including
when different from startup. Modifier editing and overview/escape round trips
must retain the staged selection and its controls.

## Findings and implementation

- The old Firefox scanner matched title leaves. Sidebery icon-only pinned tabs
  have no title leaf, and hover previews/duplicate titles are not unique tab
  identities. The shared production walker now resolves exact `tab<id>` rows
  only inside Firefox-owned Sidebery chrome, never ordinary web content.
- Failed AX reads, truncated traversal and missing chrome are not successful
  empty scans. Existing bounded continuity can preserve a recently verified
  outline during a partial read. A completed empty scan still clears it.
- Outline continuity now uses tab/session/layout identity, excluding changing
  favicon metadata. Native Chrome tab-group mapping remains covered.
- Staged modifier editing uses a key nonactivating panel, with process-local
  visible key-window input ownership covering its SwiftUI popovers. It no
  longer activates Intent and then reactivates an app to return focus.
- DBT-only runtime copies suppress retained overview/saved-draft startup steps;
  original draft launch semantics are preserved. Run preparation errors show a
  nonactivating notice rather than opening the dashboard.
- Exact start anchoring and quiet completion are detailed in
  `2026-10-05-quiet-completion-current-window.md`.

## Live evidence and unresolved boundary

The existing default Firefox profile is Firefox 157.0 with Sidebery 5.6.1 and
temporary Browser Guard 0.2.34 over the separately installed permanent 0.2.28.
No extension code/version or browser profile is changed by this patch.

A read-only probe compiling the real scanner confirmed the old walker missed
the pinned row repeatedly and the new walker resolved its exact rectangle.
That is production geometry evidence, **not** a rendered green-outline pass.

For a normal titled tab, Firefox's AX row cohort was displaced upward by 520
points while its screenshot showed the rows in the visible sidebar. The
selected row was outside its reported parent viewport. All regular rows had
the same displacement; pinned geometry was unaffected. No guessed position
correction is permitted. Foreground correlation is required before declaring
this browser-specific geometry problem resolved.

A conservative guard now rejects that displaced, complete, fitting row cohort
as incomplete. It never reconstructs coordinates, and fixtures preserve real
scrollable lists, clipped subsets, partially offscreen trees and legitimate
completed-empty results. This prevents a misplaced outline; it does not prove
that the missing regular-row outline has been repaired. The production walker
has 21 focused checks for these cases and the exact-row changes above.

CUA app-scoped clicks, Window-menu selection and keyboard actions did not
change the actual foreground: a separate read-only native observation still
reported Codex window 1556 ahead of Firefox window 118. A Firefox AX-focused
element is therefore not proof of desktop foreground. The user was asked to
bring Firefox forward and leave a DBT-marked titled tab visible. Pending that
physical handoff, actual foreground outline/start/finish acceptance is pending.

## Permanent regression discipline

`npm run qa:plan` maps the real source diff to existing behavioral suites.
`npm run test:changed` runs them serially and rejects a changing source
fingerprint. Committed changes require `-- --base <pre-change-commit>`; a clean
HEAD diff is not a certificate. Unknown code/configuration changes select all
safe suites. Both extensions and native host checks accompany native session
changes. Lifecycle executables use verified private QA roots, never daily
recovery data. Read-only PR/codex CI gates main-only publication.

The machine-readable gate deliberately leaves physical input, actual outlines,
installed identity and delayed exact-window/tab acceptance pending. This is a
standing workflow requirement in AGENTS.md and the regression contract, not a
promise that future bugs are impossible.

## Source and verification receipt

`npm run test:changed` passed all eight suites on frozen source: change-impact
accounting, session UI, Swift specs, both extensions, native host, release
readiness, AI regressions and extension lint. Fingerprint:
`2812073bc55fcdea31bbbbdf4c4ba8371f141ec8dbba92ec0357554a691c1a3c`.

- Gate evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-YCnhtD`.
- Session evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-session-checks-5RyprgI6`.
- App model: 158 isolated assertions. Notch: 165 assertions with real rendered
  content, explicitly not desktop/physical acceptance.
- Development installation and relaunch completed with `scripts/install-dev.sh`.
  `/Users/loganmondi/Applications/Intent.app`, ID `dev.loganmondi.intent`, running
  PID 10561, matches tested UUID `C3CCE36F-A855-313B-B7FE-077EE623D371`.
  Strict/deep signature verification passed; Accessibility trusted and global
  gesture listener ready. Both current browser heartbeats report 0.2.34.
- Installer correctly warns that default Firefox's permanent 0.2.28 remains
  outdated beneath temporary 0.2.34. No permanent browser-release acceptance is
  claimed; this app-only change did not publish a new extension.

Installed UI acceptance used existing tabs without navigation or a restrictive
session. Selecting one Firefox tab visibly highlighted its exact overview
window; the picker screenshot showed tab icons and the selected row. Closing
overview retained the stopwatch modifier in the staged strip; File > Quick
Focus reopened the retained selection. Opening the cooldown popover left actual
foreground PID/window unchanged (Codex 12866/1556), corroborated by native
observation. A tool-driven typing attempt did not change its value and dismissed
the popover, so **field entry is unverified**, not passed. The cooldown, stopwatch
and sole tab mark created for this QA were removed through UI; Run became
disabled, overview was closed and no restrictive session was started.
The final passive native observation confirmed no visible Intent panels and
the original foreground PID/window. Querying Intent through CUA after closing
its last visible surface reopened overview during QA; closing it and observing
Firefox plus passive native state avoided that instrumentation side effect.

Pending: ordinary actual Firefox tab outline in the foreground; physical
Caps/number and editor typing on this binary; exact DBT start and each completion
mode with a 20-second delayed native-window/browser-tab trace. Automated checks,
overview highlighting and panel geometry are not substitutes for those checks.

Publication boundary: GitHub rejected the combined push because the existing
terminal token lacks `workflow` permission; the connected integration also
returned 403 for the non-forced ref update. No permissions were expanded. The
app fixes, tests and standing regression instructions are published separately;
the workflow-only commit remains local pending authorization. Local gate
requirements apply now, but remote CI enforcement is **not yet published**.
