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
