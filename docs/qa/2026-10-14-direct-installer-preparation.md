# Private direct installer preparation

This is source and disposable-fixture evidence, not a signed artifact or live
onboarding/session acceptance. The existing notarized ARM candidate is older
than these changes and must not be promoted unchanged.

## Download and first launch

The release builder now compiles a fresh ARM64 launch app by default. Explicit
`INTENT_RELEASE_ARCHITECTURE=universal` retains cross-compilation support, but
is not Intel runtime acceptance. Reusing `.build-launch` remains restricted to
an explicitly unsigned tester preparation.

One signed application payload is packaged three times:
`Intent-Firefox.pkg`, `Intent-Chrome.pkg`, and `Intent-Both.pkg`. Each has the same
fixed `/Applications/Intent.app` destination, preinstall guard and app/helper
bytes. Its postinstall receives one fixed enum and launches the console user's
app with `--setup-browsers=firefox|chrome|both`. Each PKG is separately signed,
notarized, stapled and assessed. The compatibility DMG contains the Both PKG;
the website consumes the direct PKGs, with no ZIP/HTML setup detour.

Before opening Intent, postinstall atomically writes the non-secret root-owned
0644 receipt `/Library/Application Support/Intent/onboarding-browser-choice.json`:
`{"version":1,"browsers":"firefox|chrome|both","app_build":"<CFBundleVersion>"}`.
This survives a failed auto-open or installation at the login window. The app's
separate onboarding change must consume it only for first setup, matching the
installed build, ignoring it in Test Intent and preserving existing choices.

The manifest records each browser enum, exact asset name, byte size and SHA256,
plus source commit, dirty state, source fingerprint and declared architectures.
All new candidates have `distribution_ready=false`. The direct-download helper
refuses output without explicit qualification and matching Chrome approval.
The verifier checks actual package signatures/tickets, fixed destinations,
source-matching installer scripts, embedded browser versions, exact build/OS
metadata and identical full payload bytes/modes/links across all variants.

## Signed Firefox reuse and immutable output

`INTENT_SIGNED_FIREFOX_XPI` plus `INTENT_SIGNED_FIREFOX_SHA256` selects the exact
approved Mozilla archive. Verification requires the recorded digest, correct
Gecko ID/version, semantic manifest equality, every source file byte-for-byte,
JAR SHA256 coverage and a valid CMS signature. Mozilla certificate trust is
established by the approved AMO receipt and installed Firefox verification;
OpenSSL CMS checks integrity without pretending its system CA store contains
Mozilla's add-on trust roots. `.amo-upload-uuid` is local signing metadata and
is the only ignored source file. The approved XPI is never deleted.

The existing signed 0.2.46 archive passed this real verifier with its previously
recorded SHA256. New signing remains available if sources change.

`INTENT_RELEASE_OUTPUT` selects an empty output directory. Nonempty output is
refused rather than erased, retaining previous candidates for rollback. Use a
new directory per version/build. Source drift during packaging rejects the
candidate; commit metadata never substitutes for its content fingerprint.

## Removal and updates

Uninstall now refuses running Intent/CLI/native-host processes rather than
terminating them. It verifies the fixed system app's bundle and signer, helper
signers and exact native-host registration targets before elevation and again
afterward. Foreign destinations, symlinks and legacy launch agents refuse
without deletion. It removes only the verified system app/executables and
matching global registrations. Unknown support files, all per-user channels,
profiles, preferences and saved intentions remain. The old `--delete-data`
option is rejected. Native-host refusal tells the user to quit Firefox/Chrome.

The private tester update helper no longer downloads and executes a moving main
branch. It points to the same private tester installer and requests a normal
session finish/app exit, preserving data. Actual update/rollback acceptance
still requires the signed candidate in a disposable macOS environment.

## Checks run

- `test-signed-firefox.py`: 9 cases, including real CMS verification, tampered
  signature, changed source/manifest, omitted signature coverage and duplicates.
- `test-package-postinstall.py`: 3 methods with all browser enums, loginwindow/
  no-console cases and launch failure; receipt persists with the expected enum,
  exact build and 0644 mode. OS ownership changes and GUI launch are mocked.
- `test-package-uninstall.py`: 12 cases, using only rewritten disposable paths
  and mocked process/signature checks; refusal is read-only and success retains
  user data plus unknown support files.
- `test-download-kits.py`: 37 cases total, including direct-PKG qualification,
  size/hash/enum/path/platform checks, actual expanded-script/destination
  validation and full payload fingerprint changes.
- `test-release-readiness.cjs` passed; touched shell scripts pass `bash -n`.

The new suites are included in `npm run test:release-readiness`. No production
build, signing submission, install, uninstall, GUI interaction, publication or
live runtime qualification was performed for this packaging subtask.

## Compatibility preflight follow-up

The package preinstall now refuses unsupported hardware, macOS below 13,
unreadable/malformed compatibility probes and non-startup-volume targets before
payload installation. The ARM64 variant checks hardware capability rather than
the translated process architecture, so running Installer under Rosetta does
not reject an Apple Silicon Mac. The optional universal variant accepts both
supported architectures. The builder pins the guard's architecture/minimum OS
to the payload, and expanded-package verification rejects a mismatched or
weakened guard. Fresh Swift builds are limited to two compiler jobs.

Focused checks passed: 22 disposable preinstall test methods (including Intel,
old macOS, Rosetta, universal, failed probes and alternate-volume cases), 39
download-kit tests, the static release-readiness specification, shell syntax
and `git diff --check`. These fixtures do not constitute an actual installation
on Intel, older macOS or a clean Apple Silicon Mac. No build/sign/install ran.
