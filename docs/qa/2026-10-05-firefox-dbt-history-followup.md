# Firefox DBT follow-up: recorded activity and AX root omission

All times below are UTC on 2026-10-05. This note intentionally omits browsing
titles, page content, URLs, and browser-session values.

## Evidence boundary

Computer History was running when checked at 14:08. Its 14:00 segment's latest
record was 14:06:15; it was still unchanged at 14:12. The recent records contain
Accessibility text and input metadata, not screenshot pixels or row geometry.
They cannot establish whether the green outline was visible, nor reconstruct
consumed DBT keystrokes. This is not a physical-path acceptance pass.

The user's ready submission is recorded at 14:04:55. Firefox PID 635, native
window 119 appears at 14:05:05, 14:05:20, 14:05:24 and 14:05:26. Codex PID 12866,
native window 1556 reappears at 14:05:11, 14:05:21, 14:05:26 and 14:05:29. The
Firefox tree identifies a standard window with Sidebery and Intent Browser
Guard chrome controls. There are no recorded Firefox keyboard/mouse events or
Intent window events in this interval. Missing consumed-key events do not prove
the user failed to press the shortcut.

This test used native window **119**, not native window 118 from the earlier
background-only geometry investigation.

## Passive native/bridge observations

- At 14:13:35, Firefox was running, not app-hidden, and not foreground. Both 118
  and 119 remained in the all-window CG inventory at `(0,39,1710,1073)`; neither
  was in the on-screen inventory. AXWindows returned only one minimized dialog.
- At 14:14:47, private read-only diagnostic window-ID lookup identified that
  listed minimized dialog as **118**. In the same sample, AXFocusedWindow and
  AXMainWindow directly returned **119**, a non-minimized standard window;
  AXFocusedUIElement also belonged to 119. The private lookup is diagnostic only
  and was not added to production.
- Three repeats at 14:16:00 produced the same discrepancy with successful AX
  reads: AXWindows listed only 118; focused/main independently returned 119.
  Codex remained actual foreground and Firefox had no on-screen CG windows.
  The lack of on-screen windows does not identify which Space held 119.
- At 14:16:34, directly walking the focused 119 root returned valid Sidebery
  geometry, with zero failed AX reads using diagnostic 150 ms timeouts. The
  browser sidebar was `(0,114,280,990)`, the regular-row parent was
  `(0,168.5,280,848.5)`, and ten rows were contiguous at 38-point intervals from
  `y=168.5` through `510.5`. Active tab 17 was at `(6,282.5,268,38)`.
- The bridge snapshot timestamp was 14:05:27. Browser window 11 contained ten
  tabs, active tab 17, and was browser-reported focused. Browser window 9 had
  sixteen tabs, active tab 51, and was not browser-reported focused. Exactly one
  profile snapshot matched the current base snapshot's session.
- At 14:20:03, snapshot PID and process-launch identity matched the live Firefox
  process. Native 119's AX and CG titles matched each other and uniquely matched
  the active tab of browser window 11; only the match result was retained.

Window 119's rows did **not** exhibit the shifted complete-cohort geometry
previously observed in window 118. This does not establish whether 118 has
recovered, or whether its prior anomaly was background-only.

## Confirmed code gap and scoped correction

`WorkspaceTabOutline.scan` previously discovered candidate roots only through
AXWindows. The observed Firefox state omitted the requested standard window
from that list even though focused/main attributes exposed it. A minimized
sibling retained the same frame. This creates a concrete missing/wrong-root
path before the row walker runs; the history does not prove it was the exact
state during the user's 14:05 test.

The production resolver now unions listed, focused and main AX roots, dedupes
them with CFEqual, and excludes confirmed minimized candidates. It keeps the
existing requested geometry gate and overlapping-window title disambiguation.
Distinct same-title/same-frame roots remain ambiguous. It does not raise a
window, switch Spaces, change browser tabs, extend the 120 ms production scan
budget, guess row coordinates, or weaken the caller's browser-session binding.

Eight deterministic production-resolver regressions cover the omitted focused
root and actual sidebar walker result, duplicate roots, main-only fallback,
minimized siblings, overlapping different/same titles, different geometry, and
confirmed minimized focused roots. They supplement the prior row/cohort cases.

`swiftc -frontend -parse` for the three changed source/test files and
`git diff --check` passed. No SwiftPM build, installation, UI action, extension
change, or runtime acceptance was performed by this investigation. The parent
task owns the complete isolated gate, development installation and final live
verification. Full-suite and physical-path results remain pending here.
