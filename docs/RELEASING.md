# Releasing Intent

Intent public releases must be signed with Apple Developer ID certificates and
notarized by Apple. Unsigned local builds must never be uploaded as `Intent.dmg`.

## Required GitHub Actions secrets

- `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64`
- `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_PRIVATE_KEY_BASE64`

The two certificate secrets are base64-encoded `.p12` exports. The notary private
key is the base64-encoded App Store Connect API `.p8` file. Secrets must never be
committed to this repository.

## Publish

1. Configure all six repository secrets.
2. Run the **Signed macOS release** workflow with a version and increasing build
   number, or push a `vX.Y.Z` tag.
3. The workflow builds a universal app, signs the app and package, notarizes and
   staples the DMG, runs `scripts/verify-release.sh`, and publishes only after
   every check succeeds.
4. Confirm the release contains:
   - `Intent.dmg`
   - `Intent-Firefox-Extension.zip`
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
7. Test `uninstall.sh` both with and without `--delete-data`.

## Local QA

`scripts/build-local-release.sh` creates `Intent-local-unsigned.dmg`. It is for
local engineering only, cannot pass the public verifier, and must not be attached
to a GitHub release.
