# Tester readiness — September 5, 2026

Status: blocked for a fresh, verified tester installation.

## Release blockers

- Firefox Browser Guard 0.2.5 is Mozilla-approved and signed (version 6463010,
  file 5007181) and is published as both a versioned XPI and the stable
  Intent-Firefox-Extension.xpi GitHub asset. Its manifest now contains the stable
  self-update feed; 0.2.5 and later can update automatically. Existing 0.2.4 and
  older installs require one final manual update because those builds did not
  contain a feed URL.
- Chrome Browser Guard 0.2.5 is published as both a versioned ZIP and the stable
  GitHub ZIP. The Web Store-safe package has been accepted into draft item
  `ffgfjfpkddgimambgmahlodjjojmjnbc`, with the listing assets and privacy
  disclosures saved. The public publisher contact email was verified and the
  extension was submitted on September 6, 2026 with automatic publication enabled.
  Google reports the item as Pending Review and says review may take a few business
  days. Consumer Chrome on macOS does not auto-update unpacked extensions.
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
- 94738dd prevents Firefox's stale completion event for a replaced blank tab from
  interrupting the real startup page. It also allows the first same-host website
  shell redirect to complete, then restores the configured path restriction.
  Regression coverage includes Instagram startup, Outlook's mail-shell redirect,
  later same-host path blocking, and cross-site redirect blocking.
- 127f753 deliberately loads an existing matching Firefox startup tab once so a
  discarded or half-restored Instagram tab is never mistaken for a successful
  launch. dedd061 applies the same rule in Chrome and uses a temporary tab-scoped
  network exception for the first same-host shell redirect, then removes it.
- 0228aaa adds Firefox's self-hosted update feed, Chrome's Web Store update URL,
  and release assertions that keep package versions and update channels aligned.
- a6938a9 adds capability checks before starting browser sessions, saved-data
  recovery and permissions hardening, native-message size limits, and release
  verification gates.
- 4d0b9b4 and 6a0b9e8 implement the menu-bar lifecycle, monochrome icon, right-click
  Close Intent menu, required Shift+grave shortcut, and restoration of visible
  menu-bar placement. Prior September 4 live QA confirmed the icon, close, and
  relaunch behavior; this was not repeated while Logan was working on the Mac.

## Verification in this pass

The full npm test suite passed on the release branch after the 0.2.5 changes: Swift core, purpose
matching, accounts, Firefox and Chrome behavior, native host correctness and
memory checks, 14 hosted-AI unit tests, release assertions, and Firefox lint.
Chrome's installed unpacked copy was then reloaded from the updated `main`
checkout. The live heartbeat reported 0.2.5 with
`single-startup-launch-v1`; a real `morning watch` intention started without the
outdated-guard alert, produced one fully loaded YouTube tab, remained at one tab
after seven seconds, and was ended with browser rules confirmed inactive.
The optimized IntentApp build also passed. The installer syntax check passed;
its missing-manifest dry run now exits with a clear explanation and performs
no installation.
These are automated checks, not a claim that every UI workflow or hosted service
has been exercised live.

## Remaining acceptance work

- Confirm Firefox's currently open install prompt for the signed 0.2.5 XPI, then exercise real
  Instagram and Outlook intentions and confirm the native heartbeat reports 0.2.5.
- Wait for Google to approve and automatically publish Chrome Web Store item
  `ffgfjfpkddgimambgmahlodjjojmjnbc`, then verify the store-served version in a
  clean Chrome profile.
- Publish a complete signed and notarized Mac release with its manifest and both
  browser artifacts; verify the public download URLs and clean installation.
- Complete clean Intel and Apple Silicon installation and upgrade tests,
  permission-denial handling, offline guest use, account and calendar integration,
  scheduler wake/sleep behavior, and the physical shortcut/gesture checks in
  RELEASING.md. The automated suite does not replace those checks.
