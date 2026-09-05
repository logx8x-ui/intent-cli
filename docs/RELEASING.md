# Releasing Intent

Intent public releases must be signed with Apple Developer ID certificates and
notarized by Apple. Unsigned local builds must never be uploaded as `Intent.dmg`.

## Required release credentials

- Installed Developer ID Application and Developer ID Installer certificates
- A `notarytool` Keychain profile named `intent-notary`
- `INTENT_SUPABASE_URL`
- `INTENT_SUPABASE_PUBLISHABLE_KEY`
- `INTENT_GOOGLE_CLIENT_SECRET`
- `AMO_JWT_ISSUER`
- `AMO_JWT_SECRET`

Pass the certificate names as `INTENT_APPLICATION_IDENTITY` and
`INTENT_INSTALLER_IDENTITY`, and the notary profile as `INTENT_NOTARY_PROFILE`.
Supabase's publishable client key is intentionally safe to ship in a client app because Row Level
Security protects user data, but it is still injected by the release environment
to keep environment configuration out of source. Secrets must never be committed
to this repository; a service-role key must never be supplied to the app build.

## Publish

1. Configure every release credential listed above without committing it.
2. Run `npm test`.
3. Run `scripts/build-release.sh VERSION BUILD_NUMBER`, then
   `scripts/verify-release.sh`. The build signs the universal app and package,
   obtains Mozilla's unlisted signature, notarizes and staples the DMG, and
   refuses incomplete public artifacts.
4. Publish only after the verifier succeeds. Repository release automation is
   not active yet, so this gate must be run locally before uploading assets.
5. Confirm the release contains:
   - `Intent.dmg`
   - `Intent-Firefox-Extension.xpi` (Mozilla-signed unlisted build)
   - `Intent-Chrome-Extension.zip`
   - `release-manifest.json` (machine-readable verification metadata)

The README presents only the three user downloads. The manifest is consumed
automatically by `install.sh` and Intent's updater.

## Acceptance checks

Before calling a release stable:

1. Run the one-command installer on a clean Apple Silicon Mac.
2. Run it on a clean Intel Mac.
3. Confirm there is no Gatekeeper bypass, Control-click workaround, or source
   build.
4. Confirm Intent opens once, has one menu bar item, and the configured global
   shortcut opens and hides the overlay.
5. On macOS 15, run `scripts/smoke-test-overlay.sh /Applications/Intent.app 100`
   and confirm the process survives.
6. Upgrade over an older install and confirm `~/.intent` data is unchanged.
7. Install the Firefox `.xpi`, restart Firefox, and confirm the guard remains installed.
8. Confirm an outdated Browser Guard is rejected before any website session starts.
9. Confirm the public Firefox update feed serves the signed XPI version and the
   Chrome Web Store item serves the Chrome package version.
10. Test `uninstall.sh` both with and without `--delete-data`.

## Local QA

`scripts/build-local-release.sh` creates `Intent-local-unsigned.dmg`. It is for
local engineering only, cannot pass the public verifier, and must not be attached
to a GitHub release.
