# DBT Chrome coverage failure after Mission Control

## Reproduction

Logan physically repeated DBT with a Google Chrome tab and returned from Apple
Mission Control. The installed Test Intent became ready, then stopped about
eight seconds later with `browserWindowCoverageFailure`. This is a captured
safety stop, not a confirmed process crash. The matching read-only failure
receipt reports `window-continuity`, 15 native candidates, two AX standard
windows, and candidate counts `[0, 1]`. Ordinary native visibility had resolved
with zero unresolved targets. Evidence is preserved under
`dist/qa-20261015-two-three-finger/`, including the change-only DBT trace.

## Concrete mismatches and repair

A subsequent live public-AX/CG probe of Chrome's profile picker observed an AX
standard window titled `Who's using Chrome?`, a CG window titled `Google
Chrome`, identical 1024×822 geometry at (343,102), and browser-owned AXWebArea
URL `chrome://profile-picker/`. The old matcher necessarily returns zero
candidates for this real auxiliary Chrome window. This explains a concrete
source of the observed zero-candidate failure; the old receipt did not retain
the failed AX window's identity, so it is not proof that every occurrence is
the picker.

- Recognize this internal surface only from the exact Chrome-owned WebArea URL,
  correct bundle/process lifetime and unique geometry. A title alone, lookalike
  URL, foreign process or duplicate native candidate does not establish identity.
- Keep the picker in the observed coverage cohort as an excluded window to hide;
  it is not an allowed-app exception and cannot open another profile unchecked.
- Refresh the complete CG inventory after AX sampling so Mission Control/title
  changes cannot leave the observer matching against its earlier CG sample.
- Retain a prior binding across minimized backing-title/restore-bounds changes
  only when the same live AX object is positively minimized and fresh complete
  WindowServer inventories positively show its exact process/window offscreen.
  Unknown, visible, replaced and different-lifetime cases remain rejected.
- Persist coverage failure reasons, exact identity when known, and bounded
  discovery counts without window titles or browsing URLs for future diagnosis.

Regression fixtures cover both binding stages, misleading title/URL cases,
duplicate geometry, process lifetime, replacement AX objects, missing hidden
proof and continued exclusion of the picker. The original incompatible visible
title/frame, ambiguity and PID-reuse fixtures remain intact.

## Release boundary

Two/three-finger Notes navigation is development-only; shared browser coverage
repair applies to both channels. The experimental T adder stays excluded from
launch. Keep physical DBT/MC click-return and exact-profile installed acceptance
separate from source/reducer tests. Final gate and installation evidence will
be appended after execution. No claim of zero bugs or tester qualification is
made by compilation or notarization.

The live private website is already invite-gated; anonymous `/download` and
binary access must remain denied. Its matching Chrome Web Store listing still
reports 0.2.14 on 15 October, while source requires 0.2.46. The existing catalog
correctly stays unpinned until the agreed browser and release gates pass.

## Executed verification

All six required suites passed in `intent-change-gate-TCkbyy`: gate, session,
Swift, Firefox/Chrome extensions, native host, release/channel. Runtime source
fingerprint: `fd44804222232c0920d847a3d640f374e6ec969b3ba6f19704e2bab797a13590`.
The current observer completed 60 consecutive successful live public AX/CG
observations of Chrome's actual profile picker, preserving identity 7699.
Receipts are copied to `dist/qa-20261015-two-three-finger/`.

Both home apps installed from this source: Test Intent UUID
`B34F5893-A884-30DF-B472-B2C4DDC32F00`, launch Intent UUID
`A79B1450-34AE-3781-80DA-C9F0D3801DF2`. Installed Test Intent opens Tasks and
returns through Choose apps; both help labels specify two or three fingers.
No user task data was changed. Physical finger delivery and complete physical
DBT-to-Mission-Control click-return remain pending. `releaseReady` stays false.

The existing private website passed all 24 download tests including local
Worker/R2 behavior. Public root returns the waitlist; anonymous download page
and binary endpoint return 404. Chrome's public store still serves 0.2.14 while
this candidate needs 0.2.46, so no download catalog was falsely qualified.
