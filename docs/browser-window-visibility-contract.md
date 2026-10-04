# Native browser-window visibility ownership

This bridge addresses restore-induced macOS Space changes. Browser Guard retains
tab parking, ordering and groups; Intent's native app exclusively owns whole
user-window minimization and restoration when this protocol is negotiated.
Browser window IDs are not WindowServer IDs.

## Negotiation and wire format

- Extension capability: `native-window-visibility-v1`.
- Host capability: `native-window-visibility-host-v1`.
- The app opts the current rule occurrence into `nativeWindowVisibility`.
  Missing fields decode as false. The native lock is bound to that exact
  `startupSessionID`, not a remembered intention name or reused tab ID.
- The host enables this only for a compatible, identified browser connection.
  New ownership additionally requires a verified browser parent PID and launch
  lifetime; unavailable proof cannot create a nil-proof production claim.
- Requested native ownership and connection readiness are distinct. Once rules
  require native ownership, unavailable proof must deny a claim, not silently
  select browser-window restoration. Readiness requires negotiated host support
  and verified process identity; an extension's static feature list is not proof
  that the installed host supports it.

The extension sends `type: "windowVisibilityPlan"`, its existing
`browserSessionID` and `browserBundleIdentifier`, and a `visibilityPlan`:

```text
intentionSessionID: current startupSessionID
revision: monotonically increasing integer
windows: fully blocked user-window descriptors
parkingWindows: extension-owned holding-window descriptors
revealWindowIDs: stranded holding windows explicitly needing recovery
```

A descriptor is `{ windowID, title, frame: { left, top, width, height }, state }`.
Plans are bounded and validated; the host pins the connection's browser/profile
identity and validates the fresh active rules before accepting new claims.
Inactive or superseded intentions may submit only recovery of previously
registered holding windows with unchanged identity metadata. Such a request
cannot introduce a new claim.

`visibilityPlanReceipt: { revision, accepted }` acknowledges a durable request,
not completed restoration. An identical retry is accepted idempotently; an
altered same-revision or older request is rejected. Data is partitioned by both
browser session and intention occurrence, so the next session cannot overwrite
an accepted recovery request before the app consumes it. Accepted recovery IDs
and registered holding-window history must survive later desired-plan updates.

## Native ownership and completion

1. Require normalized title **and** bounds, unique in both directions across
   candidate native windows/profiles. Never use title-only or browser-ID guesses.
2. Bind the native CG ID to PID, process launch date and browser/profile/session.
   A user window is adopted only after AX confirms it was not already minimized.
3. Persist ownership before changing visibility. Refresh only currently blocked
   planned windows. Omission from a later plan does not erase ownership or undo
   initial Add-as-you-go hiding.
4. Restore only owned native windows with `AXMinimized=false`. Do not launch,
   activate, raise or unhide a whole browser to restore one window.
5. Verify the resulting AX state before discarding ownership. A timeout can mean
   the request is still completing. A missing presentation candidate is not
   proof of closure: use the unfiltered CG lifetime query and retain unknowns.
   Likewise, missing AppKit process/launch metadata retains the journal entry.
   Only a positive missing-process result or verified PID reuse retires its old
   process lifetime; inconclusive permission/probe failures never do.
6. Observed input, unrelated activation and a Space change end the separate
   short exact-window focus guard. Do not chase the user between Spaces.

### Enforcement outcomes are separate from plan receipts

An accepted normal-window claim is not proof of successful hiding. Native
reconciliation tracks actual AX minimized readback. A continuously unresolved
claim gets a three-second monotonic observation grace, then a specific safety
failure releases the intention without success celebration. Ambiguous identity,
unreadable AX state, failed ownership persistence and unconfirmed minimization
must not silently look like a successfully enforced intention.

The deadline is keyed by occurrence, profile, browser window and process
lifetime, not mutable title, geometry or revision. Already-owned windows use
their bound CG/AX identity even when presentation metadata changes. Verified
hidden state, omission and positive closure clear a pending failure. Current
rules, the exact current claim and live process proof are checked again before
delivery; an old callback cannot replace manual completion or stop a new session.
Parking acknowledgements and recovery remain separate. This is not an all-profile
startup-readiness gate: absent plans or unavailable process proof do not establish
that every browser window is restricted.

Native deminiaturization is not inherently nonactivating. Chrome live testing
showed an old window temporarily coming forward even with native ownership.
The bounded guard can queue exact-window preservation directly after an owned
restore, before slow AX state reads, but that is a candidate ordering improvement,
not a platform guarantee. Fresh CG/foreground checks and public input counters
fence each effect; input counters cover cancellation callbacks still waiting on
the main queue. A later corrective raise or a sampled displacement is a failed
no-pop test, even if the original window eventually returns.

## Holding windows and the identity barrier

Before moving a user's tabs into a new holding window, publish its registration
and await the native capture receipt. The host does not return `accepted:true`
for that registration until the native app has durably bound its identity.
Otherwise the moved tab can change the window title before native matching.
This capture is not an AX restoration acknowledgement. A bounded timeout retains
extension recovery metadata and never falls back to browser window restoration.

Ordinary completion does not reveal holding windows: Browser Guard first returns
their tabs and closes empty owned holders. Only stranded holders get explicit
`revealWindowIDs`. The native app ingests pending registrations at stop, retains
unresolved claims and retries accepted recovery via a generation-fenced
directory watcher. A new session cannot revive old minimize work or erase old
accepted recovery. Closed identities are discarded only with positive evidence.
The post-finish watcher tracks captured journal ownership only, not arbitrary
unmatched plans. Uncaptured holders cannot contain moved user tabs because of the
capture-before-move barrier. All stop routes stop native visibility synchronously.

## Firefox process-restart recovery

A browser restart is distinct from an extension background reload. The host
supplies `browserProcessIdentity: { pid, launched }` from its verified browser
parent, where `launched` uses Foundation seconds since 2001. It stamps the same
proof into the durable plan. Firefox parking markers retain that process proof,
the old browser session ID and intention occurrence.

An inactive extension can send `type: "windowVisibilityRestartRecovery"` with
`visibilityRestartRequest: { requestID, intentionSessionID,
previousBrowserSessionID, previousProcessIdentity }` and its current outer
browser/profile identity. The reply is
`visibilityRestartReceipt: { requestID, accepted }`.

Permission requires the exact prior durable proof, a different verified current
browser lifetime, positive evidence that the old lifetime ended, and no fresh
active intention. A missing AppKit process object alone is not death evidence.
Same-process reloads, unknown identity and unavailable probes are rejected.

Only this confirmed startup-recovery path may let Firefox restore its own
persistent-marker-owned holding windows using browser restoration. The extension
rechecks inactive rules and unchanged current generation after the reply. It is
never a timeout fallback or the normal Finish path. Unknown claims remain owned
and visibly diagnosable; they must not be silently erased or guessed into another
window.

For an extension reload/update in the **same** browser process, use the separate
`windowVisibilityRecovery` message with `visibilityRecoveryRequest: { requestID,
intentionSessionID, previousBrowserSessionID, previousProcessIdentity,
windowIDs }`. IDs are the old registered parking IDs saved in the markers, not
potentially reassigned current API IDs. The `visibilityRecoveryReceipt` queues
only native restoration of previously captured ownership. It never authorizes a
browser restore. The current process must exactly match the old durable proof;
recovery of a still-active same intention is rejected. A different newer active
intention cannot erase an older accepted recovery. This request appends sticky
recovery IDs without changing the desired plan or its revision.

## Active-session I/O

Active reconciliation keeps a cache for the current intention occurrence.
Unchanged historical files retain metadata only, not decoded titles or plans.
Modification time, size and filesystem identity invalidate atomic replacements;
failed reads are retried and never reused as authority for a new claim. Finish
forces revalidation of current records before its final capture. Recovery reads
only the exact profile/intention tuples already owned by its journal.

This removes repeated historical JSON decoding from the half-second active
loop. Directory metadata discovery still scales with retained file count; it is
not a claim of constant-time storage or a measured battery-life improvement.
Recovery records are not deleted merely to make a performance test pass.

## Required verification

- Old host/app compatibility, unknown profiles, old occurrence IDs and revisions.
- Exact duplicate retries after a lost receipt; malformed/bounded payloads.
- Duplicate titles/geometry, multiple profiles, pre-minimized user windows.
- Parking registration before tab movement; timeout/reconnect; finish immediately
  after registration; old reveal concurrent with a newer active occurrence.
- Sticky recovery across later plans; source window closed before tab return.
- Actual Firefox and Chrome window state after manual/timer/checklist completion,
  current work window and Space retained, plus delayed recovery observation.

Automated passes do not establish Space, foreground or physical-key acceptance.
See the dated QA records for the tested build and remaining limitations.
