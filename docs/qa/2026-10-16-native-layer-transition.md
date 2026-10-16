# Native offscreen layer transition — October 16

## Actual installed failure

User physically reproduced a safety stop on the installed system app 0.9.5,
202610160001, UUID 406B6AD9-0173-341C-B706-85C4ADCC14F7. The fresh 11:45 KST
receipt identifies nativeWindowEnforcementFailure, not Chrome browser coverage.
The process stayed alive. Native diagnostics show 13 targets, one unresolved:
Messages PID 18115, surface 7257, untitled and offscreen, absent from AX binding.
Selected Messages window 7256 and selected ChatGPT window 4105 were separate.

A read-only WindowServer probe of the same live identity found 7257 on layer 3,
84x77, absent from the complete on-screen query. The pending-target path retained
its previously admitted identity, but isOffscreen required layer 0. Thus a
presentation-layer change made positive offscreen evidence become unknown. The
AX fallback could not bind a non-document surface, so the bounded watcher stopped
the session. Historical diagnostics lacked the earlier layer number, so the
exact timing of the layer change relative to the user's gesture is not proven.

## Repair and protected behavior

The exact ID/PID must still exist in complete native inventory with a valid layer,
but need not remain layer zero to prove absence from the complete visible query.
The existing process-lifetime checks and offscreen monitor retain ownership of
this observation. No selection is expanded, no target is silently retired, no
window is called closed, and unknown inventory stays unknown. Returning on-screen
invalidates offscreen proof at every layer and must regain hiding before deadline.
Diagnostic offscreen rows now include the actual layer.

Regression feeds real native parsing into the tracking policy across layer 0 ->
layer 3 for longer than the failure deadline, then asserts that visible reappearance
still fails closed when hiding is unresolved. Malformed, duplicate, missing and
wrong-process inventory rejection remains covered.

## Acceptance

Automated gate, exact-source installs and live observation pending. Physical SBT
and DBT Mission Control return remain required in both channels. Prior 0.9.5
physical acceptance is failed, not pending or passed. No tester promotion.

Automated gate Fc9JTi passed all six suites on exact source fingerprint
`cd56d5a78f63e778d58368dc8a109585196715c91230aa188cd357474bd166db`.
Regression evidence is retained locally in dist/qa-20261016-layer-transition.
