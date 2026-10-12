# Installer preparation — 13 October 2026

Logan authorized finishing everything possible while deferring the notarization
credential step until he wakes up. Existing private invitation access remains
unchanged. This change does not alter session enforcement or installed app identity.

## Defect and fix

The public package preinstall killed every process named IntentApp and deleted a
legacy launch agent. That can interrupt an active session before its visibility
restoration and stop the other channel. The package now embeds a separate tested,
read-only preinstall guard. It refuses live GUI/CLI processes or failed process
inspection, symlinked destinations, unverified/different existing app identities,
malformed/foreign browser host registrations, and legacy launch agents requiring
migration. No process is killed, registration unregistered, or launch agent
removed. The postinstall no longer removes/boots out a legacy agent.

Legacy installations with launch agents require a separate safe migration; this
change deliberately refuses them instead of deleting their configuration.
The repository uninstall script remains a separate unresolved safety audit.
A real root-level installation was not performed against the daily machine.

## Verification

- Twelve disposable behavioral fixtures passed, including running GUI/CLI,
  process-inspection failure, clean and owned destinations, foreign/test app,
  malformed/foreign hosts, host/parent symlinks and legacy agents. Every fixture
  asserts existing files and links remain identical after both acceptance and refusal.
- All eight change-impact suites passed (gate, session, Swift, extensions, native
  host, release, AI and lint), source fingerprint
  `12be92cf5674ea8dedf4ad4834f8fb5c48b6dbc41b1425576f0d4a69921dd766`.
  Receipt: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-76xbav/result.json`.
- `build-release.sh 0.9.3 202610130001` completed using the explicit unsigned,
  current-arm64 tester preparation flags. Actual pkg expanded read-only and its
  preinstall compared byte-for-byte against the tested script; postinstall contains
  no process kill or launch-agent bootout. The package retains Browser Guard
  0.2.46, launch channel, T disabled, notarized=false and empty asset_url.
  This is a local QA package, not a distributable release or Intel build pass.
- Fresh official-site checks: root 200, missing/wrong-invite download 404, and
  unauthenticated download API 404. No download was enabled or published.

## Signing and release limits

Previously created Developer ID Application/Installer certificates remain intact.
A separate full-app signing attempt reached macOS Keychain authorization while
signing Sparkle. Computer Use explicitly disallows SecurityAgent interaction.
The agent stopped only its own waiting codesign process; installed apps and keys
were untouched. The temporary partially signed tree is not a final signed app.
The successfully built unsigned DMG remains a local preparation artifact.

User will complete authorization/notarization credentials after waking.
Notarization, matching approved browser distribution, actual cross-profile/off-Space
window coverage, exact finish restoration, and clean-Mac onboarding remain release
acceptance requirements. The prior stabilization QA document records those open
runtime cases. Automated passes are not physical input or installed-profile proof.
