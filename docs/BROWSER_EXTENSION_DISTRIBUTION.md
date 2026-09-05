# Browser extension distribution

Intent uses store-signed or Mozilla-signed extension packages for testers. A
version bump in source is not considered released until the browser's real
distribution channel serves that version.

## Firefox

- Firefox Browser Guard is submitted to Mozilla as a self-hosted, unlisted add-on.
- `firefox-extension/manifest.json` points to the stable HTTPS update feed in
  `firefox-updates.json`.
- The feed points to the stable, Mozilla-signed
  `Intent-Firefox-Extension.xpi` asset on the latest GitHub release.
- Every new release must update the extension version and feed together, obtain
  Mozilla's signature, replace the GitHub XPI, and verify the public asset before
  merging the feed to `main`.
- Builds older than 0.2.5 do not contain the feed URL and require one final manual
  install. Builds starting at 0.2.5 discover later versions automatically.

## Chrome

- Tester and public installs must come from the Chrome Web Store. Chrome checks
  that channel on startup and periodically, then installs newer versions when the
  extension is idle.
- The manifest uses Chrome's Web Store update service and a fixed extension key,
  preserving the ID `aibdbhjdckeeejpggfpfaghmomopjbpb`.
- Unpacked extensions are for local development only. Chrome does not turn an
  unpacked folder into an automatically updated consumer install on macOS.
- Every release must upload the new ZIP to the existing Web Store item and submit
  it for review. A GitHub ZIP alone is not an automatic-update channel.

## Release gate

Before a browser release is called ready:

1. Run `npm test` and build both extension packages.
2. Confirm the Firefox package has zero self-hosted validator errors and warnings.
3. Confirm the signed XPI manifest version and Mozilla signature.
4. Confirm the public Firefox feed and XPI return successfully over HTTPS.
5. Confirm the Chrome Web Store item serves the same version as the source ZIP.
6. Install each released package in a clean browser profile, restart the browser,
   and verify the native heartbeat reports the released version and capability.
