# Optional naming, saved slots and native Spotlight — 1 October 2026

## Delivered

- Removed the first-selection naming modal and its gates from window/app/tab clicks, double-tap marking, modifiers, native Spotlight and session start.
- A 38-point glass name bar replaces the overview logo. Naming is optional; Return in the field commits editing without starting a session.
- Unnamed runs get stable app summaries, including selected browser tab counts. Automatic titles are faded in history and saved slots. Existing explicit names remain explicit on migration.
- Click a recent title to rename it inline. Clearing the name restores the automatic summary. Renaming a saved recent run also updates its slot and replay workspace.
- Named and unnamed history can be saved. Bookmarks fill, preserve their link across restarts, and cannot create duplicate setups on repeated clicks. Failed saves/renames roll back both the app model and stored intentions.
- Saved setups appear in a horizontal row of rounded cards under the name bar. Drop one card onto another to swap their positions. Numbers 1–9 run the visible slots only in the overview; held backtick plus 1–6 still controls modifiers. Name/checklist text entry does not launch a numbered slot.
- Slots are paged on compact screens; their numbers refer to the current page. Existing order and saved data are preserved. Save animation shrinks/moves a bookmark toward its new slot; Reduce Motion skips that flight.
- Whole-app saved selections can reopen installed apps at start. Missing/ambiguous scoped windows or tabs still require review; replay never widens them into whole-app access. Preset apps stay out of overview previews and slot icons.
- Apple Spotlight remains the native system interface. Cmd–Space or the overview's Apple Spotlight button opens it; selecting an application and Return is the intended addition flow inside the overview. Leading/trailing backtick opt-in remains outside the overview.
- Native resolution now handles newer macOS AXSystemDialog roots, prioritizes the selected result's children, and protects Return while Spotlight is opening. Diagnostics record readiness/events only, never search text or app identities.
- Unnamed drafts retain modifiers when switching between overview and double-tap selection or reopening the overview.

## Automated evidence

The full `scripts/test-qa-regressions.sh` completed three passes on the final core/native-selection implementation. A last UI-only preset-icon filter and empty-replay message were then release-built and checked with the app-model harness again.

- IntentCoreSpec, including optional/automatic naming, legacy decoding, exact tab counts, rename/clear, slot ordering, nine number keys, text-editing protection, held modifier chords and draft preservation: passed.
- Existing app-stack, window scaling, browser identity, mixed gesture, restoration focus, runtime timer/checklist, Add as you go, Stopwatch and onboarding core checks: passed in all three passes.
- IntentAccountSpec: passed. PurposeMatcherSpec: passed separately.
- Firefox/Chrome rule, background, idle-work, popup connection, hidden-tab restoration and website-feature suites: passed in all three passes.
- Native host, snapshot freshness, profile isolation and performance checks: passed (performance run peak RSS 8.2 MiB).
- Extension lint: zero errors, notices or warnings. Both browser packages built.
- Release-readiness, download pages/kits, QA Chrome/Firefox/package isolation, fresh-install data preservation: passed.
- AI service: all 14 tests passed separately.
- Development/public update-channel checks and beta installer fresh/update/reinstall/system migration checks: passed separately.
- The actual IntentAppModel was tested in an isolated QA app with 17 assertions covering save, filled links, idempotence, inline rename, rename-before-save, slot swap, reading both files back, active-session guards and real disk-write failure rollback: passed, including after the final UI edits.
- A mock render of the actual name bar, slots and recent rows was visually inspected. It is not a live overview or gesture acceptance test.
- An obsolete release test requiring the retired Cmd–G launcher was corrected to verify the current global backtick monitor/fallback and Cmd–G retirement.

Full-suite logs: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-qa-checks-eBWmUinR`.

## Installed build

Installed using `scripts/install-dev.sh`, without replacing saved intentions or preferences.

- App: `/Users/loganmondi/Applications/Intent.app`
- Source and installed UUID: `7753D2E3-5768-30E9-AE3E-A568E5017DA0`
- Deep/strict codesign verification: passed.
- Installed process running; readiness reports Accessibility trusted, global gesture tap ready, single-press Carbon fallback removed.
- Native helper and embedded Chrome/Firefox sources updated together (Browser Guard 0.2.22).
- Both browser heartbeats reported 0.2.22 during this pass; this does not prove a permanent Firefox installation.

## Still requires unlocked/live acceptance

The Mac locked during the work. CUA reported automatic unlock failure twice. No physical-input or visible-live pass is claimed for the following:

1. Cmd–Space → choose a native application result → Return visibly adds its icon without launching it in front; prefix/suffix opt-in outside overview; cancellation and non-app/ambiguous results.
2. Optional blank/named sessions from overview and double-tap; inline rename, filled bookmark, flight animation, card dragging, paged slots and number-key auto-run on the installed build.
3. Fast Escape/backtick exits during previews, editors, popovers and native Spotlight.
4. Installed Firefox/Chrome exact-profile tab switching and enforcement latency, mixed single/double-tap, completion/restoration keeping the current window in front.
5. Firefox restart persistence: the default-release profile has permanent Browser Guard 0.2.20 while matching 0.2.22 is currently temporary. A Mozilla-signed matching permanent extension and restart acceptance remain outstanding.

The code/build/automated checks are complete. The tester release gate remains open until these live checks pass; no claim of zero bugs or exhaustive physical acceptance is made.
