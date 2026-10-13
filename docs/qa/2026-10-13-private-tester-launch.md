# Private tester download and onboarding

## Accepted brief and baseline

Logan approved implementation on October 13: one invite-only download page,
Firefox / Chrome / Both (recommended), direct signed installer, automatic
onboarding with that choice, Apple silicon first, existing macOS 13 minimum.
Feedback collection is explicitly out of scope. The public domain stays the
waitlist, and the T website adder stays development-only.

The app baseline is `2754a7e0005579cf458f321fd6ecb50aedfb7b95` on
`codex/name-first-intentions` in the Documents checkout. Unrelated `.superpowers/`
and `weppy-project-sync/` are preserved. The website baseline is `18a09b6`.
The installed launch QA app has UUID `DEA9ABCF-9322-32D3-BD3B-EDC35795FC2E`.
The previous notarized candidate predates this runtime baseline and is not a
qualified download.

Reported broken delivery sequence: website choice -> ZIP -> DMG -> PKG ->
instructions; browser choice never reaches Intent, profile attempts can count
as progress without a connection, and the tutorial describes retired UI.
Expected: choice -> PKG -> standard macOS approval -> Intent onboarding ->
permissions -> selected profiles verified -> real first intention.

Adjacent invariants: preserve completed onboarding and saved data on updates;
do not redirect to a public binary; do not guess an existing Firefox profile;
do not weaken coverage or restoration to make readiness pass; preserve current
Caps Lock/backtick and saved-slot controls; keep Test Intent identity separate.

## Qualification ledger

All entries remain pending until evidence from the final frozen build is linked.
An implementation or automated fixture does not pass an installed/physical case.

| Gate | State | Required evidence |
| --- | --- | --- |
| Direct packages and selected-browser handoff | Pending | All three actual packages launch matching first-run choices |
| Profile readiness | Pending | Fresh matching installed extension and exact selected-profile reply; wrong profile fails |
| Chrome delivery | Blocked | Matching approved Store version installed from Store; current public listing is 0.2.14 |
| Firefox delivery | Partial | Signed permanent 0.2.46 exists; final-build restart/enforcement still required |
| Ordinary app restriction | Partial | Baseline iLoader missing-birth-date fix passed its installed case; final build recheck required |
| Cross-profile / off-Space coverage | Pending | Reproduce historical AX-absent failure and verify actual final candidate |
| Finish restoration | Pending | Independent exact-window and Space trace, including pre-minimized sibling |
| Preset replay and resource closure | Pending | Missing apps/tabs/modifications restored; session retains remaining resources |
| Tabs / shortcuts / site controls | Pending | Matching Chrome and Firefox profile flows, physical input where required |
| Clean install and onboarding recovery | Pending | Clean account, permission denial/grant, quit/resume, first intention |
| Supported macOS / Apple silicon | Pending | Oldest supported and current OS; no Intel claim |
| Update / rollback / uninstall | Pending | Disposable behavioral tests and installed data-preserving verification |
| Private hosted artifact | Pending | Authorized bytes/hash match, unauthorized requests denied, no public asset |

## Execution notes

- `npm run qa:plan` was run before edits and reported a clean baseline.
- Chrome dashboard automation refused navigation with `Not allowed`; a targeted
  user handoff requests opening the existing dashboard, not new credentials.
- Another active chat was using Firefox/desktop for an iPhone transfer during
  initial inspection. Disruptive restriction tests wait for desktop availability.
- Packaging, website delivery and onboarding have nonoverlapping owners. Shared
  Swift builds and final frozen change-impact gate run serially after edits settle.
- Download catalog remains unpinned until every release gate is actually passed.

## October 14 integration progress

- Website source `44e8b57b09f3d3f54750a73eecd43e7f3432ca28` was built,
  saved as version 17 and deployed successfully. Deployment
  `appgdep_6ace4a80792481919e4d59074c4295f6` retains the public waitlist and
  invite-only download page, with `PINNED_LAUNCH_RELEASE = null`.
- Local website checks: 15 tests, invite cases, real local Workers/R2 checksum,
  conditional upload and ranged-read behavior, TypeScript and production build.
  Browser visual inspection confirmed the black/silver/star download layout.
  Local HTTP: public root and valid synthetic invite 200; absent/invalid invite
  and anonymous binary request 404 with private/no-store headers.
- After deployment, browser verification confirmed the custom-domain root is
  still the waitlist and an invalid invitation renders 404. Direct API browser
  navigation was blocked by the browser client; shell HTTP requests hit an edge
  403 even for the public root. Neither is claimed as hosted API authorization
  proof. Real owner upload and package-byte checks remain pending.
- The source-matching Chrome 0.2.46 Web Store ZIP was prepared after Chrome
  rule/background tests passed. SHA256:
  `ead565e9b4fb0e51a0b8fd346be013532a34215ea606ccd073bf6f70bde0a1d9`.
  Logan opened the dashboard; browser control still rejects scripting the
  extensions gallery. Upload/submission is handed to Logan, not claimed done.
- The first combined gate (`intent-change-gate-nhkgYN`) was deliberately stopped
  during session compilation after independent review found setup false-ready
  cases. It is not a passing gate. Selected profiles must survive temporary
  discovery loss, missing chosen browsers must stay pending, and an unrelated
  silent profile must not make an already-bound connection flicker.
- Another active desktop workflow continues to use Firefox. No disruptive
  app/window restriction test has been run concurrently with that work.

## Integrated source checks at 15:38 UTC

- All eight change-impact suites passed against stable source fingerprint
  `8c44cb84501850f78698c206877b1d1db793293236c30f831c55993e06806457`:
  gate accounting, session UI, Swift, extensions, native host, release,
  AI and extension lint. Evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-8lQopa`.
- The checkout now includes another chat's committed silver session capsule,
  `a80ccf62568d7a937771ce1940458f145d046816`. It is included in that fingerprint;
  none of that chat's changes was reverted or staged as this task's work.
- Review corrected three false-ready cases: discovery losing a selected
  profile, a selected browser being absent, and that browser appearing later
  without any of its profiles selected. Explicitly skipping a browser remains
  available; a silent or wrong-profile heartbeat never qualifies it.
- The earlier gate `intent-change-gate-Ovy6SI` was stopped for the third
  correction and is not counted as a pass.
- The other desktop workflow is now idle, but Computer Use reports the Mac
  locked. Installed-app acceptance waits for unlock; this gate's isolated app
  checks do not substitute for real browser or window-restoration checks.
- Public Chrome listing was refreshed and still reports 0.2.14. The submitted
  matching package and approval are not yet confirmed.
- Final packaging review found an additional compatibility gap: a plain
  component PKG did not reject Intel or pre-macOS-13 hosts. A read-only
  preinstall compatibility check and disposable tests are being added; the
  frozen gate must be rerun after those changes.

## Final automated gate at 15:46 UTC

- Compatibility refusal is implemented before file installation: ARM64 hardware,
  macOS 13+, supported startup volume, and fail-closed platform probes. It
  recognizes Apple silicon under Rosetta. Release compilation uses two jobs.
  Twenty-two disposable preinstall tests and thirty-nine package/manifest tests
  pass, including weakened guard rejection.
- The complete eight-suite gate passed again against unchanged fingerprint
  `199cf56a5431faf15e92d80ba4e3585072b2c976139651633743e322007fb2e3`.
  Evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-BAZFph`.
  Source was not changed during this run. This supersedes the earlier automated
  pass for candidate construction, without clearing any live gate above.
- Browser Guard source remains 0.2.46. The signed Mozilla artifact can be reused;
  the exact prepared Chrome Store package still needs submission/approval.
  Do not promote a future extension or update feed until compatibility with the
  frozen tester app has been verified. Chrome Store updates are browser-managed;
  this release does not claim it can disable them or pin a user's browser.

## Fresh signed package preparation, build 202610140001

- Native source was committed as `f6ab614ca5bb790cf9250750d91d2041368ae031`.
  The source-only branch `codex/selected-resource-lifetime` was fast-forwarded
  to `5ffb91f28c5cfa9c97b7fe1ca68e096f0f7ba8a2`; no main branch, tag, release
  or update feed was changed. Remote-only workflow/history files were preserved.
- A fresh ARM64 release build produced launch app 0.9.3, build 202610140001,
  Mach-O UUID `BD2706A8-5AA8-3685-9861-2D366B58E4F9`. Application and
  installer Developer ID signatures use team `Y3ZGWT477T`. Each signed
  Firefox/Chrome/Both PKG is preserved under
  `dist/private-candidate-202610140001/pending-notarization/`, together with
  the exact signed payload and a non-distributable candidate receipt.
- Actual `pkgutil --expand-full` inspection passed for all three packages:
  fixed installation destination and scripts, correct browser-choice handoff,
  matching embedded extension metadata, deep/strict app signature, and safe
  compiled launch-channel diagnostic. All variants contain the same payload:
  SHA256 `e341c76f5be361b2ecb3ab9a50979b380039fe3f9bb3c76cf566da25e7d2cb00`.
  These checks did not install the packages or launch normal app UI.
- The verifier initially rejected Apple's harmless empty `<relocate/>` element.
  Only the verifier and regression fixtures were corrected; actual relocation
  instructions are still rejected. The full release-readiness suite passed,
  including 40 download-kit tests. Signed application/package bytes were not
  modified by that verifier correction.
- Notary submission failed before upload with exit 69: no Keychain item found
  for profile `intent-notary`. The Mac is locked, and explicit-login-Keychain
  lookup also failed. This does not establish that credentials were deleted.
  Retry after unlock before asking Logan to recreate anything. No new candidate
  has an Apple acceptance ticket, staple, or Gatekeeper acceptance result.
- The candidate deliberately embeds an empty Chrome published-version marker
  because 0.2.46 Store approval is unconfirmed. After actual approval, create a
  new numbered candidate with approved matching Chrome metadata before the
  complete Chrome/Both onboarding acceptance. Do not relabel these pre-approval
  packages as ready or silently change their immutable receipts.
- No fresh package was installed or uploaded, and the website download catalog
  remains empty. Mac unlock, Chrome upload/review, fresh real-profile runtime
  tests, clean-account installation and macOS 13 acceptance remain outstanding.

## Verifier follow-up full gate, 16:03 UTC

All eight change-impact suites passed after the verifier-only change against
unchanged fingerprint
`9c90863fcc8c83301b1663c13b3b8043a0e5a249dda3f4e2da384c788f27821b`.
Evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-muvskQ`.
The signed native payload remains tied to source commit `f6ab614` and its
original `199cf56a...` fingerprint; this later check changes only verifier
tooling and documentation. No live acceptance status was promoted.
