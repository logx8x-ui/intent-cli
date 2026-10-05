# Exact-window finish follow-up — October 5, 2026

## Report and current evidence

Logan reports that ending an intention in Firefox leaves the same application
foreground but switches to another Firefox window. The acceptance requirement
is the exact working native window, not merely the foreground PID.

The existing installed app's read-only diagnostics captured a finish at
`1791188088.358989` (October 5, 17:14:48 KST):

- `begin`: controller PID 56421, target PID 635, native target window 118,
  `fromControls=false`, exact AX match by `visibleHit`.
- Native restoration dispatched `AXMinimized=false` for window 119 in PID 635.
- Immediate preservation initially reported target 118 already frontmost.
- AX queries then deferred; a Space change cancelled the guard at +0.648s.

Only counts, transient identities, timing and statuses were inspected. No tab
titles, URLs, browser content or private session history were collected.

This is consistent with the previously measured asynchronous Dock/window
deminiaturization, not a failure to distinguish browser applications. See
`2026-10-04-finish-window-lifetime.md` and the original strict Chrome finish
trace. Another delayed raise would be correction after a visible jump, not a
fix for the requested no-jump behavior.

## Safe changes and disabled preparation

The native guard now records the first window from an actual on-screen-only
WindowServer query whenever that identity changes. The finish verifier rejects
same-PID/different-window diagnostics as well as the existing trace-order checks.
No additional window raise, app activation, private API or OS preference change
was introduced.

A separate candidate at
`/tmp/intent-quiet-finish-policy-candidate-20261005.patch` prepares
`FocusSessionSpec.hiddenWorkspaceRestorationOnStop` with `.automatic` default,
including `preservingForegroundOnStop()`. Its explicit `.onUserReveal` option is
a separate product choice: keep Intent-hidden ordinary windows minimized and
hidden applications hidden until the user deliberately reveals them. This
candidate and its core regressions were removed from the primary source; they
are not shipped or enabled by this diagnostic change.

If selected explicitly, the native owner persists that policy per owned ledger
entry before any restoration, and future retries, new sessions and app recovery
honor it. Confirmed user revelation or window/process closure can retire the
entry; unknown identity/visibility retains it. Default/old journals continue
automatic restoration. Deferred ordinary entries do not keep an idle recovery
timer or file watcher running. Parked-holder closure receipts remain observed.

The preparation must not be called a completed quiet-finish fix: changing this
default requires Logan's explicit restoration choice and installed acceptance.

## Browser audit boundary

Both current extensions delegate normal whole-window ownership to the native
owner. Normal tab return uses `tabs.move`, pin repair and order normalization,
without `windows.update({focused:true})` in that return path. Active-enforcement
recovery separately fences focus by session, activation and window-focus
revision. Browser-side legacy minimized-window markers and prior-process orphan
recovery still have explicit browser reveal paths. Their migration/restart
semantics are not replaced by the dormant native policy.

Native-owned orphan parking holders are also covered by a persisted deferred
policy. Normal holders should close after tabs are safely returned; do not
delete, unhide or guess a holder solely to make the ownership journal empty.

## Verification

- `node scripts/test-finish-trace.cjs`: passed, including same PID with a
  different native window in diagnostics.
- Pure policy Swift type-check: passed.
- The separate candidate includes core regressions for automatic defaults,
  explicit policy copying, hidden/visible/unknown decisions, policy JSON
  round-trip and watcher need. These are not part of the primary gate.
- Main agent owns the full isolated Swift/app gate and installed UI acceptance.
- No desktop input, application installation, source commit or publication was
  performed by this focused audit.

For eventual quiet-mode acceptance, use two ordinary Firefox windows and two
Chrome windows, test manual and timer completion, retain 20 seconds of passive
post-finish samples, assert the exact same on-screen window/PID/Space, verify all
user tabs remain recoverable, and deliberately reopen each deferred window.
Also test restart, source-window closure with orphan parked tabs, and a new
intention before old restoration finishes. If quiet mode remains disabled,
automatic whole-window restoration is still an unresolved user-facing defect.
