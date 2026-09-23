# Name, choose, start

Intent's overview and quick marking now require a nonblank intention name before
selecting resources. A saved or replayed intention already has its name. The
onboarding purpose is reused rather than asked for twice.

## Reuse and local history

Space switches between the picker and reorderable saved slots, except when a
text editor has focus. Today and Yesterday show local run records, with replay
and save actions, not task-completion claims. `session-journal.json` lives in the
active profile directory, is written atomically with owner-only permissions,
and is not part of account synchronization. Existing saved intentions and graph
metadata are retained.

Session records are keyed by actual runtime occurrence. The ready callback
creates a record; teardown updates it once. Start failures before readiness do
not create records. Restart closes stale occurrences without starting locks.

Saved workspace replay matches unique app/window titles and exact browser
URL/title pairs against current resources, then pins current browser-session
identities. Missing or ambiguous resources require review; the app never opens
duplicate tabs or widens a missing window into whole-app access. Old saved
browser setups without replay descriptors require selecting current tabs.

## Deliberate exits and recovery

The first timer/checklist offers a local exit passcode with three random
suggestions. Store only a salted verifier in Keychain, separate from account
credentials. Incorrect entry leaves the session active. Safety Stop remains
unconditional. Reset requires macOS owner authentication outside a session.

An early passcode exit saves a recovery checkpoint. Jump back in prepares a draft
without starting restrictions. Checklist progress is retained only for unchanged
task positions/text; remaining timer seconds are retained unless the user edits
the timer. Replaying a saved slot/history entry starts tasks and duration fresh.

## Optional work periods

Require an intention supports a deadline, indefinite use, and weekday schedules
(including overnight intervals). Always-allowed apps remain accessible between
sessions. A five-minute break releases the idle gate. Failed starts and lost
browser connections release restrictions. Relaunch skips the current scheduled
occurrence; later occurrences remain configured. App shutdown is never vetoed.

Gentle hourly reminders are optional, nonactivating, dismissible, and disappear
automatically. They do not start sessions.

## Verification

- `scripts/test-swift.sh`: core, purpose-matching, and account suites.
- Habit-session regression cases cover serialization, occurrence deduplication,
  recovery progress, local-day grouping, overnight schedule boundaries,
  ambiguous replay, and corrupt-history preservation.
- Browser background and native-host specs protect existing bridge behavior.
- Live UI and release-install evidence are recorded in the task completion;
  automated specs alone do not prove physical shortcuts or browser rendering.

Before ten external testers, also exercise sleep/wake, multi-display gestures,
passcode entry/recovery, and real Chrome/Firefox selections on their machines.

### Implementation pass: 2026-09-23

Debug and release builds, all three Swift suites, the complete extension suite,
and native-host specs passed. The final development bundle was installed and
relaunched at `~/Applications/Intent.app`. The installer used macOS Python after
the Homebrew Python/expat combination failed; no user data was reset.

Live computer control reported that the Mac was locked. Consequently, rendered
UI, physical shortcut timing, Keychain credential entry and live Chrome/Firefox
multi-window acceptance are still pending. Normal Firefox's heartbeat was fresh;
Chrome's heartbeat was stale at inspection. The auxiliary Firefox QA profile
has no permanent add-on; the normal Firefox profile has the matching package.

Changes are pushed on `codex/name-first-intentions`, not main's automatic beta
channel. Creating a draft PR through the GitHub integration returned HTTP 403;
the branch remains available for review. Complete live acceptance before merge.

### Live follow-up: 2026-09-23

Verified in the installed app with native UI controls:

- Blank/whitespace names keep Choose disabled; no app cards can be selected
  before naming. A valid name reveals the workspace and enables modifiers.
- Saved intentions display their names, app icons, Review and Run. Space returns
  to the existing named workspace without losing the draft.
- Selecting Reminders enables Run. A normal session started, finished through
  the File menu, and appeared in Today. Clicking history restored the named
  selection without starting it.
- A one-minute timer displayed remaining time. Ordinary Finish showed the
  locked-session explanation. It ended automatically after approximately 60.5
  seconds; the persisted occurrence has zero remaining time and an end date.
- A one-task checklist displayed its unchecked task. Checking it ended the
  session and persisted completedTasks [0].
- Firefox supplied its current tab list. Chrome initially supplied no current
  tabs, then reconnected during inspection without extension modification;
  both heartbeat files became fresh on extension 0.2.14. Chrome selection and
  deselection enabled and disabled Run respectively.
- The first timer setup offered the recommended exit-passcode dialog. Not now
  was selected for QA; no user credential was entered or changed.

Not yet verified: physical global single/double-backtick timing (synthetic key
input did not exercise the global path), user-entered passcode and recovery,
work-period schedules/breaks, drag reorder, multi-window browser replay and
sleep/reboot behavior. Native menu clicks are not evidence of global-hotkey
acceptance. Chrome extension settings could not be opened because computer-use
URL policy blocks that page; no workaround was attempted. The actual Intent
tab picker was rechecked after its independently observed heartbeat recovered.

Three locally named QA runs remain in Today as evidence; existing user
intentions were preserved. No public beta release was published by this pass.
