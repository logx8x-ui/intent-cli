# Signed launch candidate — 13 October 2026

## Completed Apple security preparation

Logan created and securely stored the notarization profile himself, then approved
codesign's Keychain access. `notarytool history --keychain-profile intent-notary`
independently confirmed working credentials. No password was captured in chat,
source, logs, or memory.

The earlier temporary signing tree lost a scratch file while its authorization
was pending. Recovered the previously verified unsigned package into the ignored
persistent `dist/notary-preparation-20261013/` folder. Signed the full app,
Sparkle nested code, native helper and global CLI/host using Developer ID
Application; strict deep signature verification passed. Signed the installer
using Developer ID Installer and signed the DMG with Developer ID Application.
The candidate is launch-only, T disabled, macOS 13+, ARM64; it is not an Intel
build or a qualified downloadable release.

Apple notarization submissions accepted:

- Initial signed DMG: `16846556-7cee-481b-94ca-d423bf33d005`.
- Corrected installer: `664b826f-fa41-4370-b803-cfa6cc6fa9d5`.
- Final DMG containing the stapled corrected installer:
  `b3ba8d7d-4e63-4e51-a9dc-92db8ba0907b`.

The app, corrected installer and final DMG have validated stapled tickets.
Mounted the final DMG read-only; its actual contained installer also passes
stapler validation and `spctl --type install`. The DMG passes
`spctl --type open --context context:primary-signature`, and the app passes
`spctl --type execute`. All report `Notarized Developer ID`. No app was installed
or user window/tab configuration changed by this packaging check.

Local evidence, including submission receipts, checks and checksum, is in
`dist/notary-preparation-20261013/candidate-verification.json`.
It explicitly has `distribution_ready=false`; no public asset or feed was promoted.

## Installer relocation fix

The original inferred pkg metadata contained `<relocate>` for
`dev.loganmondi.intent`. Installer could relocate an update onto an existing
per-user app instead of the intended global destination. Added a component
analysis policy that pins the launch app and all nested bundles to their exact
payload locations and requires strict bundle identifiers. Rejects missing app,
foreign destinations, traversal/absolute paths and malformed component trees.
The actual corrected package has no relocation entries.

The build pipeline also staples and assesses the signed package before placing
it in the DMG, and signs the DMG before its notarization. This preserves an offline
installer ticket inside the delivered disk image. The prior preinstall ownership
and closed-app guard remains intact; the rebuilt candidate contains it exactly.

Three component-policy unittest methods passed, including recursive pinning,
idempotency, preserved version behavior, missing-app refusal and nine malformed
or foreign input subcases. Twelve preinstall fixtures remain passing.
All eight frozen change-impact suites passed, fingerprint
`b2d26481673b193a5391a900990941025917f4e04f73b1925e96e2dcbaf0f7a1`;
receipt `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-CX0Gmj/result.json`.

## Distribution and live acceptance

Latest local Firefox 0.2.46 ZIP remains unsigned. The existing Firefox Mozilla
session is signed in and shows the newest unlisted approved version as 0.2.43;
Chrome's separate Mozilla session required login. A native Firefox upload page
was opened without creating credentials. Firefox switched to the user's YouTube
page during navigation; requested exclusive short UI use before uploading.
No extension submission or installation is claimed here.

Existing cross-profile/off-Space coverage, exact finish restoration, approved
matching browser distribution, Intel/clean-Mac checks and uninstall safety audit
remain separate release requirements. See the preceding stabilization QA note.
Apple notarization and automated suites do not establish those runtime passes.
The public domain remains waitlist-only and invite downloads remain disabled.

## Firefox submission follow-up

Logan explicitly yielded Firefox for submission. Uploaded
`dist/firefox/intent_browser_guard-0.2.46.zip` after comparing all 18 archive
entries byte-for-byte against current source. Existing add-on
`485649d659c2420c9778` retained its unlisted/on-your-own distribution. Mozilla
validation reported no errors or warnings; desktop Firefox selected, Android
unselected. Source question answered No because the archive contains readable
unprocessed files exactly matching source, with no code-generator/minifier step.
Submission completed as version record `6571198`; portal explicitly displayed
`Version Signature Pending`. Signed-XPI download, permanent installation and
matching-profile QA are not yet established. No AMO API credentials created.
Screenshot evidence: `/Users/loganmondi/.codex/artifacts/intent-release-20261013/mozilla-submission.png`.

The previous paragraph describing no submission is superseded by this follow-up.

## Firefox signing and installed-profile completion

Mozilla subsequently approved unlisted version 0.2.46, version record 6571198,
file 5115335. Downloaded through the existing authenticated developer session
to `dist/firefox/intent-browser-guard-0.2.46-signed.xpi`. Its SHA256 is
`5fe3ad9af1d122f6c74b5458f17fd811b531a48d7de17918a9d9beed5e6c7606`.
Mozilla signature metadata is present. All 16 non-manifest source files match
byte-for-byte; the manifest matches semantically, with Mozilla JSON formatting
changes only. This supersedes the preceding pending-signature status.

The Firefox local file picker would not enable Open for the XPI, including the
supported Add-on From File path and standard all-files filter. Cancelled the
picker and installed the update through its official Mozilla download link.
No additional permissions relative to 0.2.42 were requested; private-window access
was left unchecked. Firefox reported the add-on was added. Actual Add-ons Manager
shows 0.2.46 enabled, and its toolbar popover reports Connected to Intent.
Matched the observed extension UI UUID to `ykomjweq.default-release`; its exact
installed add-on record is active, signedState=2 and location=app-profile.
That establishes a normal signed installation and bridge connection, not a
restart pass or enforcement/finish-restoration acceptance. No active intention
was interrupted: both channels' browser rules and the launch lease were inactive
before updating. Screenshots are in the same local evidence folder,
`mozilla-approved.png`, `firefox-installed.png` and `firefox-connected.png`.

Chrome developer-portal creation via browser control returned Not allowed;
read-only inventory found no new portal tab. Did not bypass that refusal. The
public Chrome Web Store still reports 0.2.14, independently verified against
its official listing; matching 0.2.46 distribution remains unqualified.
No public download, main branch, release tag or update feed was changed.
