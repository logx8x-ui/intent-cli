# Tester stabilization sweep — 12 October 2026

## Scope and evidence boundaries

Continue the existing launch stabilization, preserving daily data and the
separate Intent / Test Intent channels. T remains development-only. No waitlist,
download availability, public release feed, account, or OS grant is changed.
Logan confirmed the preceding installed Spotlight existing-app selection looks
correct and no longer offers an unwanted removal X.

The starting source was `a5b8eb923fb07c60318d6494c5b921ea55773160` on
`codex/name-first-intentions`. The initial full change gate passed all eight
suites (gate, session, Swift, extensions, host, release, AI, lint), fingerprint
`915ebef3c7ba6db0a835115638431ff8faa40d5d9d55655d9d64e9180205de85`.
Passing that baseline did not establish release readiness: the focused audits
below found uncovered failures.

## Reproduced defects and regressions

- Native resource exhaustion used preview candidates, which omit tiny windows
  and turn a failed WindowServer query into an empty list. Lifetime now uses raw
  native identities and treats unavailable/incomplete evidence as unknown.
  Exact selected windows remain exact; whole-app replacement windows count;
  positively confirmed browser-only closure remains independent of native query
  availability. The isolated Swift suite passed after this fix.
- Tab searches ignored newly permitted search tabs after the original selection
  closed. Both extensions now publish only their current allowed search ledger;
  the native monitor accepts its exact occurrence UUID when the modification is
  enabled. Old/unselected tabs, stale occurrences, holding pages and forbidden
  navigation cannot extend an intention. Swift and both browser VM suites passed.
- A hostile hostname such as `google.com.evil.example` passed the search rule.
  Native, Firefox and Chrome now use the same static snapshot of Google's
  [official supported domains](https://www.google.com/supported_domains), with
  parity fixtures and regional-domain / hostile-suffix checks. There is no new
  runtime or build network dependency.
- Chrome's startup loop continued after Finish or replacement. The red VM
  baseline failed five of six deferred boundaries (URL update, DNR installation,
  completion-storage write). Revision and exact pending-effect ownership fence
  subsequent effects. Ten actual-background VM fixtures pass: six interruption
  boundaries, definitive first/partial URL failures, rejected-after-effect URL
  readback and uncertain reload suppression. Completion is recorded only after
  successful opening/activation. A deliberate early-completion mutation fails.
  Partial progress is local to the current worker; interrupted-worker recovery
  is not established by these fixtures.
- Saved replay kept durable claims after a preflight failure that never wrote a
  command, permanently blocking retry. Cleanup now retires only this attempt's
  exact never-attempted IDs. Actual production-service QA fixtures exercise both
  browsers, repaired preflight, real mailbox/receipt effects, cancellation,
  rejection, disconnect, write failure and a lost-receipt timeout. Written or
  uncertain effects stay protected against duplicate creation. Swift passed.
- Firefox retained active rules after native connection loss. Current-port
  disconnect/connect/write failures release enforcement immediately; stale
  ports cannot disable a newer connection. Pending old-port activations stop.
  Real visibility-helper VM tests preserve recovery ownership; Firefox passed.
- Both browsers delayed inactive Instagram/YouTube DOM rules behind window
  restoration. Held-restoration fixtures failed before the change. Inactive
  rules now broadcast immediately; asynchronous broadcasts are fenced to their
  originating revision so they cannot overwrite a replacement. Both suites pass.
- Corrective restoration could raise a target that had moved offscreen during
  AX IPC. Each main/raise/activate effect now requires fresh positive identity,
  onscreen and actual Boolean minimized evidence plus current/input fences.
  Production effect-boundary fixtures pass. This safety fix does not certify
  that deminiaturizing another window never displaces the working window.
- Malformed live engine metadata could be interpreted as idle by installation.
  Strict schema and liveness checks now refuse unverifiable live ownership;
  stale dead state permits recovery. Fourteen isolated Python tests passed.

- Independent review found Chrome's generated network rules still accepted
  Google lookalike domains even though its JavaScript helper had been fixed.
  Actual emitted dynamic/session-rule fixtures reproduced the defect. Sixteen
  bounded exact-host regex partitions now cover all 187 official domains:
  2,244 allowed URL and 770 rejected URL checks pass. The longest expression is
  244 ASCII bytes. Actual Chrome RE2 compiled support remains a separate check.
- Chrome native postMessage exceptions cleared the port without releasing its
  active rules. A current-port loss helper now releases policy/connection proof
  immediately, retaining recovery ownership and rejecting stale-port callbacks.
- Chrome network blocking was delayed behind window restoration. Inactive DNR
  cleanup now proceeds independently, with serialized revision-fenced effects.
  Review additionally caught and fixed stale dynamic-rule cache acknowledgement,
  a failed inventory read falsely interpreted as empty, and identical inactive
  heartbeats failing to retry while restoration was held. Nine real-background
  network scenarios pass; four deliberate mutants fail. This verifies the
  asynchronous API/model boundaries, not installed Space/foreground behavior.

## Earlier candidate status

The final source gate passed all eight suites, with source fingerprint
`815244987c55e1c478bd22eb9a479479a7ff41b74012026e62c83d24a05dc230`.
Receipt: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-5UkTcL/result.json`.
The native helper and both extension manifests advertise `0.2.44`; matching
Firefox unsigned source ZIP and Chrome development/store ZIPs were packaged.
Installed acceptance is recorded below when verified. Source or fixture success
is not evidence that the daily browser has a matching permanent extension.

## Installed QA and newly reproduced release blocker

In the existing Chrome **Intent QA** profile, the unpacked Browser Guard
`aibdbhjdckeeejpggfpfaghmomopjbpb` advertised `0.2.44` and its popup reported
**Connected to Intent**. A positively focused naming field accepted the QA name;
clicking Show tabs removed focus from the naming field. This verifies that
specific UI path through automation, not every naming/replay path.

Selecting two local QA tabs and pressing Run reproduced the exact modal twice:
"Could not confirm Chrome's current windows... This intention has not started."
Content-free diagnostics identified unique native matches for the two QA windows
but no AX exposure for another profile's Chrome window. Its CG match was unique,
with the same process birth, yet it was not in the successful AX enumeration.
Reloading the connected QA extension did not resolve this failure.

The old incomplete-coverage loop reused the original observation bracket. It now
requests a fresh correlated snapshot after the latest observation, retaining the
same original five-second deadline and generation fences. Independent review
confirmed it does not accept stale/incomplete coverage. It does **not** solve
persistent AX absence, which also affects runtime hiding and restoration.

Optional browser API window-state readback is now passed through both extensions
and the native helper; old/missing values remain unknown. The failure packet
includes these state strings but never titles, URLs, or profile names. This is
diagnostic foundation, not permission to reinterpret off-Space as minimized.
A safe subsequent fix must either freshly verify an already-minimized unselected
window without acquiring restoration ownership, or implement a paired,
durably owned exact-profile Chrome minimize/restore backend. Simply skipping
preflight or copying Firefox's minimize-only bootstrap would be unsafe.

During the later browser API probe Chrome's DevTools self-XSS warning blocked
pasting the read-only regex-support expression. It was not bypassed. The temporary
inspector was closed. No actual RE2-support result is claimed from that attempt.

The candidate above was installed serially through the explicit local development
installers, with automatic opening suppressed. Both app/helper signatures passed
`codesign --verify --deep --strict`. These are local ad-hoc signatures, not
Developer ID or notarization acceptance. Both executables are arm64, macOS 13+:

| App | Bundle identity | Executable UUID |
| --- | --- | --- |
| Intent | `dev.loganmondi.intent` | `3F34679B-A42B-3977-8AAE-85F72897AA6D` |
| Test Intent | `dev.loganmondi.intent.test` | `5A9738EC-4A27-3249-8948-CD6476621E8D` |

Both installed bundles contain the exact candidate Chrome code and `0.2.44`
manifest. Main Intent was relaunched with its launch-channel lease, with no active
intention. Reloading the QA profile's unpacked extension produced **Connected to
Intent**. This is connection acceptance only; it does not clear the earlier Run
failure or establish Test Intent permission/enforcement acceptance. Disposable
QA tabs and the sibling QA window were closed, leaving the original QA tabs and
other profile intact; the temporary local page server was stopped.

A later read-only, profile-local presence query also exposed a cold-profile
discovery gap: the newly reloaded QA extension had a fresh heartbeat without a
tab sidecar, so normal profile enumeration could not discover it. A correlated
reply from the older other-profile worker reported no window-state field. That
missing value remains unknown; it is not evidence of minimization or a reason to
bypass coverage.

## Follow-up fixes and installed app-only failure

Fresh-profile discovery was reproduced in both actual background VM harnesses:
the first healthy native connection sent a heartbeat without publishing its
current profile/tab inventory. A read-only populated-window bootstrap now
publishes actual observations for that exact current port/profile. It carries
no request IDs or complete-inventory authority, so it cannot certify absence.
Independent review also caught a failed-first-query availability hole; the
pending bootstrap must survive transient failure and retry on a later heartbeat
without requiring a reconnect.

Both browser backgrounds passed 23 bootstrap scenarios, including retry on the
same healthy connection, malformed/transition inventories, three durable-profile
storage recoveries, held-query coalescing, replacement-port fences, and Chrome
preview deferral. Independent review passed. The full extension suite initially
caught an old idle test expecting Firefox to publish fabricated empty inventory;
the repaired harness verifies one actual populated first-connection query and
then quiet forced/ordinary idle work in both browsers. The full extension suite
passed after that test repair.

The local installer previously checked idle state before building, then killed
the app before writing files; a draft/start could race that check. Local installs
now require both GUI channels closed, recheck after building and under the shared
private engine lease, and retain that lease through helper retirement and all
bundle changes. They do not kill a running GUI. Independent review additionally
caught the shipped CLI, which does not acquire this lease; exact installed and
supported development CLI processes must also be refused. This is a local
installer fix; legacy public package/uninstall paths remain separate.
Thirty-three isolated Python installer fixtures and independent review passed,
including exact known CLI paths/aliases, pre-mutation refusal, a CLI appearing
under the lease, private file validation and child lock inheritance. An arbitrary
unleased legacy executable launched after the last check is outside the
script-only lease contract; it is not claimed prevented.

A subsequent installed **ChatGPT-only** Run with no modifications also failed:
the engine stopped before becoming ready because excluded apps/windows could
not be positively hidden. Spotify rejected whole-app hiding and supplied an
empty AXWindows array; several named Codex windows were likewise absent from
that successful array. The engine released restrictions, recorded
`nativeWindowEnforcementFailure` with `becameReady=false`, and retained zero
hidden-workspace restoration records. This is a release blocker, not a passed
ordinary-app blocking or manual-finish check.

Content-free public AX probes found real main/focused window references despite
the empty window list: one exact Spotify native match and one exact Codex match.
These positive references justify a bounded, deduplicated same-process reader;
they do not establish coverage for other unmatched named windows. No title or
URL was included in the diagnostic outputs. No accessibility permission or
vendor-specific accessibility attribute was changed.

The new public window collector has separate primary-enumeration provenance.
Independent review caught and fixed two negative-evidence consumers: supplementary
roots cannot authorize Firefox bootstrap absence or classify an unmatched native
surface as non-user. Both reject an enumerator that omitted any positively exposed
root. Native CF arrays and every element type are validated before AX calls.
The production collector/type-boundary fixtures and the full session/Swift suites
passed. The matching installed follow-up was tested below.

## Reviewed follow-up candidate

The final frozen follow-up source passed all eight suites (gate, session, Swift,
extensions, host, release, AI, lint), fingerprint
`e381fa5a7b7986581f2422254fda465005a6cb96c9fe11185b3193aec8f09269`.
Receipt: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-2gj3e3/result.json`.
Helper and both browser manifests advertise `0.2.45`. Earlier partial/failed
follow-up runs (`XPubyE`, `e9T1ye`) are not this acceptance receipt.

Both local channels were installed serially through the guarded transaction,
with automatic opening suppressed. Launch UUID:
`36286602-17B5-36BF-88C2-4CEF29E44EAF`; Test UUID:
`38059447-EBBD-3386-B04B-0FE2B4EE2EE7`. App and native-helper strict signature
verification passed; these are local ad-hoc signatures. Both extension packages
and the Chrome Store ZIP built successfully; no package was published.

Installed Chrome QA verified Browser Guard `0.2.45`, its embedded source path,
reload and **Connected to Intent**. An exact-one-window ChatGPT Run still stopped
before readiness: the positive Spotify fallback was matched and restored, but
two excluded named Codex windows remained absent from public accessibility.
An exact Spotify-window blacklist Run likewise stopped safely when that named
off-Space window was not exposed. Both failures released restrictions and left
zero hidden-workspace records. This does not establish successful ordinary-app
blocking or exact-window finish acceptance.

The disposable Chrome-tab Run failed during **activation**, before window
coverage evaluation. It did not retest or clear the earlier cross-profile
coverage failure. Read-only public AX probes confirmed repeated successful empty
enumerations for the missing off-Space Spotify/Codex windows; no extra permission
issue was identified. A missing exact window cannot be replaced by a guessed
window or treated as safe absence.

The optional naming field accepted a QA name and lost keyboard focus when a
window selection was clicked. Only the disposable Chrome QA tab and extension
details tab were closed afterward; original user tabs were preserved.

## Activation-race follow-up (0.2.46)

Two additional production regressions were reproduced and repaired:

- Chrome emitted a temporary `WINDOW_ID_NONE` during window activation and
  retired the exact in-flight request before real focus confirmation. The
  existing bounded owner now survives unknown/no-focus transitions. Positive
  focus on another window still cancels; expiry, connection, profile, session
  and rule fences remain. Four new actual-background cases and the full Chrome
  suite pass, including expiry without late resurrection and stale-port events.
- The actual native host deduplicated an unchanged snapshot after successfully
  delivering activation of an already-active tab. App startup requires a fresh
  observation, so this suppressed acknowledgment could cause a timeout. A
  separate current-profile activation refresh now permits one ordinary snapshot
  timestamp renewal within three seconds after successful dispatch. It adds no
  snapshot request ID, discovery ID, complete-inventory flag or authoritative
  sidecar. Both actual-host regressions pass, including invalid/foreign/stale/
  future command denial, one-shot idle deduplication and expiry.

Startup failure diagnostics now distinguish process selection, application
activation, command dispatch and confirmation from native coverage evaluation.
Only IDs, hashed session components, timestamps, counts, booleans and enum values
are recorded; no URLs, titles or profile names. Independent read-only review
found no defect in these three changes.

The final frozen `0.2.46` candidate passed all eight automated suites,
fingerprint `b23197f0b91a7f6812ae44091e3c168249082e57e7f2d37999c154beb9c7d850`.
Receipt: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-6JgjIa/result.json`.
Both local apps were installed serially through the guarded transaction:

- Intent (`dev.loganmondi.intent`), launch/local QA, UUID
  `5817049D-4ABA-3C8D-AD0F-FE52D7B000EF`.
- Test Intent (`dev.loganmondi.intent.test`), development/local QA, UUID
  `C970F8E6-C3ED-378F-BE9C-A08F22BFAD83`.

Strict app/helper signatures passed. Both embedded browser components matched
all fifteen source code/configuration files per browser and advertised `0.2.46`.
Firefox, Chrome and Chrome Store packages built locally. The post-install source
fingerprint still matched the gate. These are arm64 local ad-hoc builds, not
signed/notarized distributable releases.

Installed Chrome UI verified `0.2.46`, the embedded component path, reload and
**Connected to Intent** with the launch app running. The disposable selected-tab
Run positively confirmed fresh exact-session, active and focused activation.
It then failed at **coverage-ambiguousIdentity**: the other profile reported a
maximized browser window whose named native identity was omitted from public AX
observations before and after the inventory request. That profile had one native
candidate but zero continuously observed eligible matches. The prior coverage
blocker therefore remains reproduced, while the earlier activation-stage
failure is cleared for this one installed path. The app stopped safely before
the intention started, released browser rules and retained zero hidden-workspace
records. No ordinary-session/finish acceptance is implied. The QA tab was closed
and the original three QA-profile Chrome tabs were verified preserved.

The popup initially reported reconnecting while both apps were intentionally
closed for installation; the native host requires a live engine owner. With the
launch app running, reload connected normally. This was not a new permission
failure. The permanent Firefox profile remains older and is not claimed to have
passed matching `0.2.46` installed acceptance.

## Remaining release gates

- The reproduced cross-profile AX-absent Chrome Run failure above.
- The installed ChatGPT-only native hiding/readiness failure above.

- Exact-window and Space preservation during ordinary restoration. Previous
  independently sampled two-browser-window runs displaced a sibling window;
  the later same-PID check is insufficient to clear that failure.
- Permanent matching Firefox and Chrome components, with restart acceptance in
  the exact tester profile. The current public Chrome listing is older than the
  candidate; old downloaded artifacts must not be presented as this build.
- Developer ID signing and notarization for the downloadable app; a local stable
  development signature is not a distribution signature.
- Clean-machine denied/granted permission onboarding, first run, reconnect,
  sleep/wake, Safety Stop, saved replay, data-preserving update and rollback.
- The local installer preparation/selection race is repaired and covered by
  thirty-three fixtures. Legacy public package/uninstall paths still kill by
  process name or remove shared host registrations broadly; an arbitrary
  unleased legacy executable is outside the local script-only lease contract.
- Localized Instagram Stories controls and mobile YouTube coverage before those
  configurations are claimed supported.

Keep automatic updates disabled for the first cohort. Use one pinned candidate
with matching extensions, begin with three to five friends, and collect private
content-free diagnostics plus expected/actual behavior. Reliability failures are
development work; tester questions should primarily establish usefulness.
