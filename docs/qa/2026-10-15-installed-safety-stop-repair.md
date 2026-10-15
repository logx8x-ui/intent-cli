# Installed native-window safety repair

Source: `dc65854e0673e28ddf71166a367d989978d8115a`; runtime implementation is
`3c9b1a2`. No additional runtime source edits were necessary for this occurrence.
The prior eight-suite gate and production/development controller results are
recorded in `2026-10-15-mission-control-and-task-workspace.md`.

## Reproduction and installed-copy mismatch

The 15 October 10:10 occurrence was a DBT startup safety stop, before readiness,
about 3.68 seconds after starting. The running executable was the older
`~/Applications/Intent.app` (UUID `DEA9ABCF-9322-32D3-BD3B-EDC35795FC2E`).
It did not contain the prepared native-window fix. ChatGPT/Codex PID 66745 had
selected window 4105 and unbound sibling windows 4129/4157. A fresh read-only
CG/AX inventory positively observed those siblings offscreen. Ordinary excluded
applications were already successfully hidden. This evidence explains this
occurrence; it does not certify every reported Mission Control transition.

## Installed and observed

- Installed current development source with `scripts/install-dev.sh`, then the
  launch channel with `scripts/install-dev.sh --launch-local`. One compiler
  worker; both engines closed normally before replacement; data preserved.
- Test Intent executable UUID: `B6ED4B16-7858-345E-B73D-634D11888C07`.
- Local launch executable UUID: `84053AA0-017D-39FC-896B-FAB9BE2E2D60`.
- Test Intent Spotify-only session became ready and remained active for several
  minutes. Test Intent ChatGPT-only session became ready in about 0.66 seconds,
  positively verified siblings 4129/4157 offscreen, and had zero unresolved
  hiding targets. It ran for about four minutes and ended by requested Quit,
  not `nativeWindowEnforcementFailure`.
- Local launch ChatGPT-only session became ready in about 0.65 seconds with the
  same exact selected/sibling window IDs and zero unresolved hiding targets.
- Updated the separate root-owned `/Applications/Intent.app` through the normal
  macOS Installer. The local repair uses the same freshly built launch
  executables and resource bundle, retains production signing identity and
  onboarding, and uses the existing preinstall/component/postinstall policies.
  Build `202610150001`; UUID matches the local launch build above. Developer ID
  signature, notarization, stapling, Gatekeeper, and visible Installer success
  passed. Its installed process was confirmed at `/Applications/Intent.app`.
- The system installation's ChatGPT-only session also became ready in about
  0.64 seconds with zero unresolved hiding targets.

Evidence: `dist/qa-20261015-live-safety-stop/` contains before/after diagnostic
snapshots and installed identities. `dist/local-repair-202610150001/` contains
the private local repair, exact source/binary evidence, and packaging inputs.
Notary submission `a6333d09-e3eb-4054-bb7d-6ba839d75baa` was Accepted.
This maintenance package is not a qualified tester release; nothing was
published or pinned on the download site.

## Still pending

App-targeted keyboard automation did not reliably exercise global backtick or
Apple Mission Control input. Dock/Mission Control handles timed out; app-window
screenshots cannot establish the global Mission Control display. Therefore the
physical SBT/DBT → Mission Control → click allowed window journeys remain
pending. A user check was requested after installing every copy. Do not report
attempted shortcuts, successful startup, or the source regression suite as a
pass for that physical transition.

The separate Firefox finish-focus issue and prior release blockers remain open.
No new task-workspace physical acceptance or general restoration acceptance is
claimed here. Both development and launch retain the safety stop for genuinely
unverifiable visible excluded windows.
