# DBT current-window start and quiet completion — October 5, 2026

## Accepted behavior and cause

Logan confirmed physical Caps Lock + backtick Run works. The follow-up clarified
that DBT starts on the tab/window where Run is invoked, and every normal finish
leaves the window being used **at finish**, not the original start window.

Two independent native effects violated that contract:

- Quick selections suppressed launch steps but `FocusLock.runStartupSteps()`
  still activated the first fallback app afterward. Activating an already-active
  browser can select another window in the same process.
- Completion deminiaturized other owned windows. Public macOS accessibility
  deminiaturization is asynchronous and may change window/Space; a delayed raise
  only corrects an already-visible jump. Prior traces confirmed target window
  118 was correctly captured while deminiaturizing window 119 caused a Space
  transition. PID-only checks did not distinguish these windows.

## Implementation

DBT captures a `FocusStartAnchor` before asynchronous browser discovery: exact
native window/PID, and for a browser its profile session, browser window and active
tab. It is revalidated after refresh, before model rule publication, and before
the native worker installs enforcement. A changed window/tab cancels rather than
raising an old target. The actual `.quickMark` route is independent of onboarding
teaching state. Anchored DBT performs no fallback/app activation; overview and
saved-launch destination semantics remain unchanged. Normal restrictions still
apply: this does not silently allow an excluded window or tab. Whitelist Add As
You Go keeps its existing permission to adopt the current unselected tab. Its
runtime-only startup resources seed the actual browser rules and native initial
hide owner with the current tab/window; this is not merely a preflight allowance.
Always-blocked presets still win, and marked/saved drafts are unchanged.

An anchored start also does not replay legacy recovery before enforcement or
attach a legacy parking-recovery watcher in blur mode.
Modifier editors use their nonactivating key panel instead of activating Intent
and later activating a previous app, so their underlying work window stays the
anchor. The live modifier field-editor behavior remains a separate acceptance
item from deterministic factory/style tests.

Normal GUI completion (`stop`, checklist completion, timer/end-time expiry)
uses `.onUserReveal` native restoration. All restrictions and input guards stop;
the app does not reopen other windows or applications. Windows it minimized stay
available in the Dock, and hidden applications can be deliberately reopened in
the usual macOS manner. User-owned tabs and windows are not closed or deleted.

The policy is durable **before** every owned hide/minimize/parking capture, not
only at finish. Retry, Intent restart and the next intention cannot reveal an old
deferred window. Confirmed user revelation or process/window closure retires
ownership; unavailable identity/visibility retains it. Each acquisition has a
controller ownership ID so explicit Safety Stop or failed-start cleanup restores
only that attempted/current controller's changes. Previously deferred entries
remain deferred. Legacy CLI specifications keep automatic restoration.

Repeated sessions are explicitly handled: an older quiet window that remains
positively minimized satisfies new browser coverage without transferring its
ownership. A user-revealed old window relinquishes the old entry before a new
effect. Ordinary applications/windows that the next session hides again get that
new controller's ownership before the hide, so its Safety Stop can undo its own
effect. Unknown visibility is not treated as hidden or revealed.

Quiet completion's five-second native diagnostic is observation-only: no AX
lookup/raise, activation or corrective focus effect. It captures the exact
visible current native window, never a stored start-window identity. Ordinary
deferred entries create no background recovery timer or file watcher. Parking
holders retain the existing event-driven closure watcher until resolved.

## Browser receipt and recovery boundary

Current native-owned browser tab return uses tab moves, pin repair and order
normalization, not a browser-window focus request. Native parking ACKs mean a
durable captured identity/plan was accepted, **not** that the holder became visible.
If an original source window closed, an automatic orphan reveal request does not
override quiet completion. Its exact holder stays recoverable in the Dock; the
browser can settle its native-reveal retry queue without deleting those tabs.
An actual emptied-holder closure receipt retires native ownership directly.

No extension source, capability or published version is changed here. Legacy
pre-native minimized-window markers and full-browser-process restart recovery
still contain browser-side restoration effects and are a separate migration/
recovery acceptance boundary. Do not claim those untested paths satisfy the
normal current-profile no-jump contract.

## Verification

- Pure quiet-restoration policy type-check passed.
- Existing exact-window finish trace verifier fixtures passed.
- Added actual browser visibility-store regressions for durable holder capture,
  same-process reload recovery and idempotent receipts, persisted quiet policy,
  user revelation and exact closed-holder retirement.
- Added DBT startup regressions for permitted current Firefox window 118 versus
  excluded same-process window 119, unresolved/Intent windows, explicit startup
  steps, overview defaults and browser-startup specification copying.
- Full isolated app gate, development installation and installed/live acceptance
  are owned by the main agent. This focused implementation did not run SwiftPM,
  post desktop input or claim a physical current-window acceptance pass.

For live acceptance, start DBT from one of two same-browser windows and compare
the exact active tab plus native window before/after startup. At finish capture
the current (possibly different) work window, then sample at least 20 seconds
after the diagnostic `startedAt`. Verify no foreground/Space/window changes and
deliberately reopen the previously minimized window. Test manual, timer and
checklist completion separately from explicit Safety Stop/error recovery.
