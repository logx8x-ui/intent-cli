# Tester readiness — September 5, 2026

Status: blocked for a fresh, verified tester installation.

## Release blockers

- Battery-optimized Browser Guard 0.2.3 is Mozilla-approved and signed (version
  6462862, file 5007033), installed locally, and published as
  Intent-Firefox-Extension.xpi on GitHub. The native heartbeat confirms version
  0.2.3 and capability single-startup-launch-v1. Its source matches the submitted
  package. This extension asset does not update the older v0.8.1 Mac binary.
- GitHub's latest binary release is v0.8.1. It has an unsigned Firefox ZIP and
  no release-manifest.json. A dry run of install.sh returned HTTP 404 for that
  manifest. Do not claim the current one-command installer is usable yet.
- The local signing identity check returned zero valid code-signing identities.
  Developer ID Application and Installer certificates and Apple notarization
  are required to produce the distributable Mac release described in RELEASING.md.

## Fixes already on main

- 1d39a16 and 9200c45 make website startup run once per intention session.
  Persisted startup session IDs prevent reconnects and guard restarts from
  repeating startup. Redirect recovery does not reload the original startup URL.
  Both browsers have regression coverage for redirects, repeated refreshes,
  concurrent synchronization, duplicate URLs, and a late first browser tab.
- a6938a9 adds capability checks before starting browser sessions, saved-data
  recovery and permissions hardening, native-message size limits, and release
  verification gates.
- 4d0b9b4 and 6a0b9e8 implement the menu-bar lifecycle, monochrome icon, right-click
  Close Intent menu, required Shift+grave shortcut, and restoration of visible
  menu-bar placement. Prior September 4 live QA confirmed the icon, close, and
  relaunch behavior; this was not repeated while Logan was working on the Mac.

## Verification in this pass

The full npm test suite passed against main at 1f7d99a: Swift core, purpose
matching, accounts, Firefox and Chrome behavior, native host correctness and
memory checks, 14 hosted-AI unit tests, release assertions, and Firefox lint.
The optimized IntentApp build also passed. The installer syntax check passed;
its missing-manifest dry run now exits with a clear explanation and performs
no installation.
These are automated checks, not a claim that every UI workflow or hosted service
has been exercised live.

## Remaining acceptance work

- Exercise a real Outlook intention once the updated guard is installed.
- Publish a complete signed and notarized Mac release with its manifest and both
  browser artifacts; verify the public download URLs and clean installation.
- Complete clean Intel and Apple Silicon installation and upgrade tests,
  permission-denial handling, offline guest use, account and calendar integration,
  scheduler wake/sleep behavior, and the physical shortcut/gesture checks in
  RELEASING.md. The automated suite does not replace those checks.
