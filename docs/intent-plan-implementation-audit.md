# Intent plan implementation audit — 23 September 2026

The four-page Intent Plan and TLDR is the baseline, with Logan's later correction:
**Name → Choose → Start**, with naming required before selecting any resource.

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Name first, overview and quick marking share a draft | QuickSelectionController and QuickSelection | Live empty-name gate, named selection; user confirmed physical overview shortcut |
| Space opens saved slots and remains text in text fields | Overview event monitor and IntentSavedSlotsView | Live switch to saved slots and back; text-editor guard inspected |
| Vertical saved slots, icons, Run, drag reorder | IntentSavedSlotsView and journal.slotOrder | Live list and controls; reorder source inspected |
| Today/Yesterday, replay and save without completion scoring | IntentSessionJournal and IntentSessionNotesView | Live actual runs, history replay and empty-history cleanup |
| Unique occurrence records, no failed-start entries | FocusLock onReady/teardown | Core occurrence deduplication tests; readiness-only persistence inspected |
| Safe current-window/tab matching | SessionWorkspace.resolve | Tests cover new IDs, new browser lifetime, missing and ambiguous scopes |
| Saved runs reset tasks/timers and use current settings | QuickSelection.applySessionConfiguration and prepare | Regression covers updated saved settings without widening resolved targets |
| Optional first-use passcode, confirmation and three suggestions | IntentExitPasscode | Setup dialog inspected; actual user credential entry remains untested |
| Early-exit passcode, no completion question, unconditional Safety Stop | finishActiveSession and FocusLock | Normal locked Finish blocked live; credential paths inspected |
| Jump back in: editable draft, task progress, exact remaining duration | Journal recovery and QuickSelectionController | Persistence tests and source review; end-to-end passcode recovery untested |
| Timer/checklist first completion wins, one-time explanation | Session limit and setTaskCompleted | Each completion path live-tested; combination notice source inspected |
| Require an intention: deadline, indefinite, weekdays/overnight | IntentWorkPeriodSettings and WorkPeriodSchedule | Schedule boundary tests; live work-period checks recorded below |
| Timed breaks, separate work-period end, essential apps usable | takeWorkBreak/endWorkPeriod/idle FocusSessionSpec | Source inspected; Safety Stop independent of credentials |
| Restart releases current work, preserves future schedules | model.load, shutdown and occurrence suppression | Restart code and schedule tests; physical reboot untested |
| Gentle opt-in reminder | IntentGentleReminder | Source inspected; no automatic session launch |
| Onboarding one real session, advanced shortcut lesson later | IntentQuickGuideView | Source inspected; existing onboarding state preserved |
| Failure releases restrictions and retains named draft | readiness callback and interrupted-workspace callback | Draft no longer cleared on accepted-but-not-ready start; live follow-up below |
| Preserve unreleased development builds | Development bundle marker and update-manager guard | Public release updater is unchanged; dev build must survive quit/relaunch |

## QA data

Removed only the three test occurrences named QA name first / QA checklist from
23 September. The original journal was backed up locally before cleanup. No
saved intention, user history record, account, or schedule was removed. Both
Today and Yesterday should remain empty until an actual user session runs.

## Boundaries

Implementation is not the same as completion of the ten-person pilot. The plan's
pilot measures and hardware acceptance checklist still require real testers:
physical double-tap timing, multi-display/Spaces, sleep/reboot, and passcode entry,
cancellation/reset and recovery. No claim of zero bugs or completed pilot is made.
The changes remain on codex/name-first-intentions until public-release acceptance.

## Final follow-up evidence

All three Swift suites passed, including the new replay-settings regression.
The development/public packaging regression executes the real beta plist
construction and confirms only local development packages carry the updater opt-out.
The beta packaging command runs this regression before producing its artifacts.
Release builds for Intent, IntentApp and IntentNativeHost passed and were installed.
The installed app signature passed verification and its Mach-O UUID matched the
release binary: 0A452236-26BD-325A-BE18-54321C950025.

Live checks on the final build: Today and Yesterday displayed Nothing yet;
Require an intention started, entered a timed break, and ended normally; a
named Reminders session started and Safety Stop released it; reopening the
workspace preserved its name and selected Reminders target without restarting.
The one additional interruption-test record was backed up and removed by exact
occurrence ID. Final history record count is zero. No work period remains active.
A final quit/relaunch retained the development build and again displayed the
Name → Choose → Start screen with Today/Yesterday both Nothing yet.
