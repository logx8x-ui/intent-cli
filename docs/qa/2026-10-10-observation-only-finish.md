# Observe completion without correcting focus

## Reported sequence and adjacent behavior

Running an intention hides unselected apps/windows. Finishing must restore only
Intent-owned visibility changes, including older deferred entries, while the
exact app, native window, browser tab and Space where finish happened stay in
front continuously. Prehidden/preminimized user windows must remain unchanged.
The current quiet-completion failure remains a release blocker.

The layout request was completed separately before this investigation. Its
installed acceptance does not certify this finish path. Source base for this
next defect: `5c142bd`, primary `codex/name-first-intentions`. The required
`npm run qa:plan` was run before source edits.

## Cause and bounded experiment

The existing `restoreOwnedWorkspace` path creates an active focus guard. After
native unhide/deminimize, it sets the captured window main and raises it; a
five-second loop may activate/raise again. This mixes the native restoration
effect with corrective focus effects, so previous live traces cannot establish
which operation first displaces the current browser window.

Experimentally remove corrective effects from that owner while retaining visibility ownership,
identity safeguards, retries and independent observation. Use the installed
candidate's normal start/finish actions through supported native automation.
Capture the exact foreground native window before finishing and continuously
sample its ordering for at least 20 seconds afterwards. If native restoration
still raises another window, keep the defect open and investigate the visibility
effect itself; never repair the trace with another raise or delayed activation.

## Required acceptance

- Core policy proves no observation transition dispatches focus effects.
- Actual owned restoration/readback retains unresolved entries and retires only
  confirmed visibility restoration; user-owned hidden states are not adopted.
- Frozen serial changed-source gate and release build pass before installation.
- Installed candidate identifies its app UUID and exact Chrome profile/component.
- Independent native foreground trace has no window jump or corrective effect;
  exact active tab and Space observations remain separately qualified if absent.
- A native restoration failure is recorded as FAIL, not hidden or relabeled.

## Results: FAIL; experiment not shipped

- Experimental fingerprint
  `2b6617c1c624542dcc5c95c650bf2d9d8d7f952251a4c0f05e0d1c03a1aba65b`
  passed all eight frozen serial suites in `intent-change-gate-UZSmNJ` and the
  release build. The candidate was development-installed as UUID
  `D329B4F1-F4F0-3050-B205-4E1FCD7E4796`, PID `31843`.
- Two disposable daily-profile Chrome windows were created through supported
  native UI. Custom names initially caused `coverage-ambiguousIdentity` and the
  intended startup failure alert. Rules stayed inactive. After removing the
  test-only names and using distinct ordinary page titles, the same selected
  tab started successfully. Custom-named/identical-frame browser windows retain
  an outstanding startup identity case; do not declare that matrix passed.
- The ordinary run selected tab `1733681423` in browser window `1733681422`,
  native window `4489`, profile `2185d8c3-8155-4165-8a86-e3fa4c1209e2`, PID `665`.
  Native ownership covered three unselected Chrome windows plus other hidden
  apps. The automated Shift-grave attempt did not end the session; its trace is
  not Finish acceptance. The native Settings/File menu was then used for cleanup
  and an uncorrected restoration observation.
- At menu finish the observer bound working window `4489` underneath Intent's
  controls. It recorded Chrome windows `769`, `510`, then `4504` displacing it at
  roughly 0.285, 0.992 and 1.905 seconds. The independent sampler likewise recorded
  those ordered windows at 0.182, 0.913 and 1.827 seconds. No corrective guard
  operation existed in the experimental source. Revealing still displaces the
  underlying browser window in this flow; removing correction alone is not a fix.
- The recorder retained 34.79 seconds after finish. Its maximum observed gap was
  305 ms and the foreground remained the deliberately opened Intent Settings
  host, so it also fails the 75 ms/exact-app acceptance limits. This is positive
  displacement evidence, not a clean hotkey/timer finish or a single native
  effect isolation. Exact tab and exact Space identity remain unverified; public
  Space-change notifications are captured separately.
- Rules became inactive and newly owned entries were restored. The prior stale
  Notes entry remained as it had before testing. Both disposable windows were
  closed after verifying their QA URLs; user tabs and saved entries were kept.
- Evidence and the unshipped runtime patch are preserved in
  `/Users/loganmondi/.codex/artifacts/intent-quiet-finish-observation-20261010`.
  The four experimental runtime/policy/spec files were reverted to the completed
  layout source. Retained changes are read-only trace tooling and this evidence.

The trace verifier now rejects every attempted AXMain/AXRaise/activation,
including a sampled already-front target or failed dispatch. It checks 50 ms
requested sampling, 75 ms actual gaps, independent native-query failures and
public Space-change counts. Tiny floating-point JSON rounding is accepted;
slower declared sampling is not. Passing it still cannot prove exact browser-tab
or private Space-ID continuity.

## Final source and installation

After reverting the experiment, all eight serial suites passed again in
`intent-change-gate-uXf8L6`, fingerprint
`6b1164861ba2a8bc77e2db080ab65f9f1e825250eab4c8d433c56f7ee8ae009c`.
The completed layout runtime was reinstalled at
`/Users/loganmondi/Applications/Intent.app`, UUID
`F2018616-15B2-357C-B171-BA44ACAD6E2C`, PID `93180`; the source release binary
and installed executable have the same UUID. Deep strict signature validation
passed. Both native helpers reconnected, rules were inactive, and an independent
onscreen-only WindowServer query showed no Intent window. No runtime source
files retain the experimental patch.

Firefox's daily permanent component is still 0.2.42 against embedded 0.2.43;
that exact-profile integration remains incomplete. This QA-only follow-up adds
no runtime behavior and does not turn either outstanding browser case into a
pass.

Next isolate a supported browser-owned quiet restoration operation before
replacing native effects. Do not publish the observer-only runtime as a fix or
add a later activation, off-screen move or deferred visibility reveal to pass.
