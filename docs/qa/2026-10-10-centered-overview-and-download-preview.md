# Centered overview and private download preview

## User sequence and acceptance

The larger overview left the open windows unevenly distributed and visually
weighted to one side. Open windows must be the central, primary interaction;
saved slots, naming, recent history and modifications surround them at quieter
proportions. Preserve large previews, source aspect ratios, equally scaled
siblings, visible captions, individual hover/selection and log dragging.

An app added through Apple Spotlight currently appears inside a large material
card with a border and duplicate caption. Present a larger app icon without
that background card. Preserve an accessible app name, selection state and the
existing remove-addition action.

After installed layout checks, continue the next queued restoration diagnostic
with disposable resources. Do not label a failed native restoration as fixed.
Then prepare a separate local/private download website using the current
waitlist visual language. Its primary action leads into browser setup, with
Both recommended. Validate the preview flow and distinguish actual available
artifacts from unfinished release/signing work. Do not deploy the waitlist or
publish the private prototype.

## Baseline and verification

- Primary branch: `codex/name-first-intentions`, baseline `8b5dd35`.
- `npm run qa:plan` ran before edits; unrelated `.superpowers/` and
  `weppy-project-sync/` remain untouched.
- Root owns desktop/build/install; layout agent owns only the pure packer and
  its geometry regressions; website discovery is initially read-only.
- Test actual production header measurements, centered distribution, caption
  avoidance, dense and sparse window sets, root history dragging, staged icon
  presentation and removal. Run the frozen changed-source gate and release
  build, install matching development components and inspect the result live.
- Browser/physical gestures, quiet restoration and distribution readiness need
  their own observations; a geometry pass cannot certify them.

## Results

### Implemented

- The packer retains its largest shared preview scale, then compacts and centers
  app groups using their visible preview area. The movable history panel remains
  an obstacle; captions and equal sibling scale remain protected.
- The optional name field is 460 pt maximum; saved slots are 76 pt high in an
  82 pt row. Two-line names retain their full line height. Drag/run/delete behavior
  is unchanged.
- Staged placeholders use square layout footprints and a standalone icon up to
  128 pt. Their material, outline and duplicate caption are gone. The remove X
  stays inside the hover bounds, with an accessibility removal action.

### Automated and installed acceptance

- Frozen serial changed-source gate passed all five applicable suites (gate,
  session, Swift, extensions and host), plus the release build:
  `intent-change-gate-YVeDsp`, fingerprint
  `25cca140916853af812cacd50aadd9415a10c6332d025192535e5b00ca70e4ab`.
- Regressions cover sparse/mixed/dense packs, left/right history obstacles,
  source aspect ratios, shared scale, real header/footer measurements, long
  saved names, and transparent staged-icon rendering in both selection states.
- Development-installed `/Users/loganmondi/Applications/Intent.app`, bundle
  `dev.loganmondi.intent`, UUID `C3E60A09-FBB0-3A9A-A703-B7D64D4B9657`.
  Installed and release executable UUIDs match; deep strict signature check passed.
- Live native UI: existing mixed app windows remained large with clear captions;
  history moved from upper-left to upper-right and back with obstacle avoidance;
  the Firefox tab drawer opened and closed. These were UI/automation observations,
  not physical keyboard acceptance.
- Reviewing an existing saved workspace staged closed Messages as a larger
  standalone icon. Clicking its X removed it; Messages never launched, rules
  stayed inactive, and the saved definition was not changed.
- Closed the overview. An independent onscreen WindowServer query found zero
  visible Intent windows. No intention was run during these layout checks.

### Explicitly unverified or still failing

- Apple Spotlight opened. A synthetic Return launched Calculator normally rather
  than exercising Intent's interception; Calculator was closed again. This is
  not a Spotlight physical-input pass. The staged icon was independently checked
  through the shared saved-workspace review path described above.
- Saved-workspace review reported one item needing selection. Its old browser
  reference and the Firefox component mismatch were not resolved by this layout
  change; saved replay is not marked passed.
- Embedded/native Browser Guard is 0.2.43; the daily permanent Firefox component
  remains 0.2.42. Exact-profile integration needs the matching permanent package.
- Quiet completion remains the blocker documented in
  `2026-10-10-observation-only-finish.md`. Read-only follow-up narrowed the next
  experiment to one disposable nonbrowser window restored at timer expiry,
  without tab parking or the corrective guard. Normal recovery still enables
  AXMain/AXRaise corrections, so another ordinary run would not isolate the
  native effect. No new runtime restoration change or clean live restoration
  pass is claimed here.

### Separate private website

- Created outside the repository at
  `/Users/loganmondi/Documents/Codex/intent-download-preview`.
- Served only at `http://127.0.0.1:5186/`; no deployment or waitlist change.
- Three-step flow defaults to Firefox + Chrome (recommended); Back retains the
  choice, keyboard radio navigation works, and each browser gets its own setup.
- Nineteen local tests and module syntax validation pass. Live IAB checks at
  1280x720, 390x844 and 320x740 verified the flow, focus, motion pause and clear
  responsive content. Fixed a 2 px decorative-fade overflow at 320 px; all three
  steps now have scrollWidth equal to viewport width. Browser warning/error log
  was empty. Viewport override was reset and the preview left open.
- Download artifacts intentionally remain unavailable: no verified matching
  current app/browser release exists. The design never claims an install or
  download completed. Release/download and clean onboarding acceptance remain
  distinct from this local prototype's verified navigation.
