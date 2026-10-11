# Launch and development channels

Intent uses one source repository and two compiled build channels. Work on and test the development channel first, then promote a specific tested commit to a launch release. Two repositories would duplicate fixes and make browser/app version alignment harder to audit.

| Channel | Build policy | Intended use |
| --- | --- | --- |
| Development — Test Intent | Compiled with `INTENT_DEVELOPMENT`; T website adder available | Logan's personal development and acceptance testing |
| Launch — Intent | Default compilation without that definition; T website adder unavailable | Verified downloads from `https://livewithintent.app/download` |

The launch policy removes the T keyboard route, the add-tab entry control, and the direct website-adder action. A preference or a relabelled plist cannot enable it. Saved intentions, ordinary browser selection, modifications, Spotlight app selection, and the other current features share the same code and data format. Changing channel does not convert or delete intentions.

## Installation ownership

Both apps can be installed together. Their app identities, preferences, keychain services, URL callbacks and writable workspaces are separate:

| App | Bundle identifier | Local data | Local source install |
| --- | --- | --- | --- |
| Intent | `dev.loganmondi.intent` | `~/.intent` | `~/Applications/Intent.app` |
| Test Intent | `dev.loganmondi.intent.test` | `~/.intent-test` | `~/Applications/Test Intent.app` |

The launch identity preserves the existing Intent permissions and data. Test Intent requires its own macOS Accessibility, Input Monitoring and Screen Recording grants through onboarding. On its first launch, Test takes a one-time copy of durable saved intentions, completed recent history, saved-slot order, replay workspaces and selected visual/shortcut preferences. It excludes authentication, active-session recovery, browser transport, window effects and login state. Later edits remain independent; nothing is continuously mirrored back into Intent. Test currently uses a local guest workspace with cloud sign-in disabled, so a test change cannot overwrite the launch account's remote workspace.

Only one **running engine** may control global input, window effects or Browser Guard. The apps coordinate through an exclusive advisory lock and a small owner record in `~/.intent-engine`; this directory stores no intentions or credentials. Opening the other app requests an idle handoff. An active intention or selection workflow refuses the switch until it is finished or closed. A crash releases the lock, and stale owner metadata cannot authorize a connection.

Browser Guard still connects to the fixed native-host name `intent_native_host`. Only the running lease owner registers its bundled helper. Each helper verifies the owner's compiled channel and generation before transport and effects; an old connection exits when the owner changes. The installer never registers a helper or steals the active browser connection. Verify the chosen app path, matching extension version and exact profile connection after a handoff.

For an explicitly authorized development install from this checkout:

```bash
./scripts/install-dev.sh
"$HOME/Applications/Test Intent.app/Contents/MacOS/IntentApp" --print-build-channel
```

The diagnostic should print `development`. It exits before app initialization, preferences, saved data, or native-host registration. The release verifier requires this diagnostic's marker and metadata before querying a candidate executable; do not send this flag to an arbitrary older app, which might open normally.

For an explicitly authorized **local launch-policy QA build**, use `./scripts/install-launch-local.sh`; its diagnostic prints `launch`. Both local installers build distinct scratch directories, use distinct CLI aliases (`test-intent` and `intent`), and refuse to replace an active engine, including an older app-only intention that has no browser rules. Set `INTENT_LOCAL_INSTALL_NO_OPEN=1` when intentionally installing both before choosing which to open. These local ad-hoc-signed builds are not public notarized downloads.

Use the matching browser components and the exact selected profiles for acceptance testing. A development build does not consume public launch or beta updates. Compilation tests prove the feature policy, not physical keyboard input, browser routing or macOS permissions; those require installed acceptance checks for each app and a channel handoff.

Standalone installation of a published app uses `install.sh`, not a source build. For a release audit, pin the verified tag explicitly rather than relying on the installer's generic `latest` default:

```bash
LAUNCH_TAG='launch-0.9.4' # Replace with the verified, published tag.
INTENT_RELEASE_BASE="https://github.com/logx8x-ui/intent-cli/releases/download/$LAUNCH_TAG" ./install.sh
```

The published installer checks the manifest's DMG checksum, notarization ticket, installer signature and publisher Team ID before installation. The launch page additionally requires the launch channel, T disabled, and matching signed/browser distribution metadata. Installing a new release preserves data; deleting data or resetting onboarding is a separate action.

## Browser setup

The download page offers Firefox, Chrome, or both. The app discovers local browser profiles, lets the user choose them or select all, and opens setup for those profiles. Profiles contain the user's accounts; there is no separate Google-account extension installer, and Intent does not ask for account passwords.

- Launch Chrome setup opens the official HTTPS Chrome Web Store page in the chosen profile. The published store version must match the packaged Browser Guard version, including when updating an existing installation.
- Development Chrome setup opens a local guide in that profile. Chrome rejects `chrome://extensions` supplied through external launch arguments; the guide explains how to open it manually and load the development folder. A matching development installation receives connection guidance rather than reinstall instructions.
- Firefox installs the matching Mozilla-signed XPI. When the selected profile is already running, Intent activates its known owner and copies the setup address for the user to paste into the address bar. A closed profile is opened explicitly by its profile path. This avoids silently opening setup in another profile.

The user must confirm extension installation in the browser. macOS must also grant the required app permissions. These confirmations cannot be silently bypassed. Verify the native connection and exact Browser Guard version after installation and again after restarting each browser.

## Prerequisites for a public launch artifact

The download catalog must remain disabled until these prerequisites and the acceptance gate pass. Do not substitute an unsigned tester DMG, an unpacked extension, a beta asset, or an older signed XPI merely to make a download button work.

1. Apple Developer Program membership, with **Developer ID Application** and **Developer ID Installer** certificates and their private keys installed in Keychain. This Mac currently has no usable Developer ID signing identities; the owner must finish Apple's enrollment/certificate setup.
2. A usable notarization Keychain profile. Create it interactively with `xcrun notarytool store-credentials intent-notary`; supply credentials in the prompts, not in source control or release notes.
3. Protected release configuration for the account backend and Google Calendar OAuth. See [Accounts](ACCOUNTS.md) and the configuration checks in `scripts/build-release.sh`; never commit secrets. Release builds refuse incomplete protected configuration.
4. Mozilla signing credentials available securely to `scripts/sign-firefox-extension.sh` as `AMO_JWT_ISSUER` and `AMO_JWT_SECRET`. Verify the returned signed Firefox artifact's actual manifest version and signature against this source revision. A portal approval or previously signed version is insufficient.
5. For Chrome or both-browser kits, the existing official store item must actually serve the exact current Browser Guard version. Store approval must be verified before setting the approval variables below. If Chrome is not ready, a verified Firefox-only release is possible.
6. The manual GitHub commands below require an authenticated `gh` CLI with permission to create releases in `logx8x-ui/intent-cli`. If it is unavailable, the authenticated GitHub release API or browser can carry out the same draft, upload, verify, and publish steps. This is independent of Apple and browser signing.

Current browser approval and live acceptance evidence belong in the focused `docs/qa/` release note, because that state can change while store reviews run.

## Build and verify a candidate

Freeze the source revision, run the applicable tests and live acceptance, then package that revision. Do not build a candidate from a dirty tree containing unreviewed fixes. The tests should cover the changed behavior and its adjacent working flows; a passing source suite is not installed-app or physical-input acceptance. Follow [the session UI regression contract](session-ui-regression-contract.md).

```bash
npm ci
npm run test:changed -- --all

# Choose a new unused launch version; never overwrite a published tag.
LAUNCH_VERSION='0.9.4'
LAUNCH_BUILD="$(date -u +%Y%m%d%H%M%S)"
LAUNCH_COMMIT="$(git rev-parse HEAD)"

# Use the exact identities from the owner's Keychain.
export INTENT_APPLICATION_IDENTITY='Developer ID Application: NAME (TEAMID)'
export INTENT_INSTALLER_IDENTITY='Developer ID Installer: NAME (TEAMID)'
export INTENT_NOTARY_PROFILE='intent-notary'
```

For a **Firefox-only** release, ensure no previous Chrome approval variables remain:

```bash
unset INTENT_CHROME_WEB_STORE_APPROVED INTENT_CHROME_WEB_STORE_VERSION INTENT_CHROME_WEB_STORE_URL
```

For **Chrome and Firefox**, only after checking the exact version on the real store:

```bash
export INTENT_CHROME_WEB_STORE_APPROVED=1
export INTENT_CHROME_WEB_STORE_VERSION="$(node -p "require('./chrome-extension/manifest.json').version")"
export INTENT_CHROME_WEB_STORE_URL='https://chromewebstore.google.com/detail/intent-browser-guard/ffgfjfpkddgimambgmahlodjjojmjnbc'
```

The version assignment does not verify publication; it records the independently verified version. A store URL alone is insufficient to produce a Chrome kit.

Then build the default launch channel and verify its packages:

```bash
./scripts/build-release.sh "$LAUNCH_VERSION" "$LAUNCH_BUILD"
./scripts/verify-release.sh dist/release/Intent.dmg dist/release/release-manifest.json
/usr/bin/python3 scripts/build-download-kits.py dist/release
```

`build-release.sh` compiles release products without `INTENT_DEVELOPMENT` in separate architecture build directories. It signs and notarizes the universal app/installer, obtains a matching Mozilla-signed XPI, and writes `release-manifest.json` with `channel: "launch"` and `website_adder_enabled: false`.

Verification checks Apple signatures, Team ID, notarization, architectures, compiled channel, and the embedded/external extension versions and hashes. Kit creation checks the manifest, canonical artifact names, checksums, XPI signature marker, and approved Chrome store version. Firefox-only configuration creates `Intent-Firefox.zip`; approved Chrome configuration also creates `Intent-Chrome.zip` and `Intent-Both.zip`. Stale Chrome/both kits are removed when only Firefox qualifies.

Do not set `INTENT_ALLOW_UNSIGNED_LOCAL`, `INTENT_TESTER_PRERELEASE`, or `INTENT_TESTER_USE_CURRENT_ARM_BUILD` for public launch packaging. Those paths produce explicitly local/tester artifacts and cannot pass the download-kit gate.

## Manual promotion

Use a new immutable `launch-<version>` tag. First upload a draft release with explicit assets; do not upload a wildcard containing local unsigned output:

```bash
LAUNCH_TAG="launch-$LAUNCH_VERSION"
gh release create "$LAUNCH_TAG" \
  dist/release/Intent.dmg \
  dist/release/release-manifest.json \
  dist/release/Intent-Firefox-Extension.xpi \
  dist/release/Intent-Chrome-Extension.zip \
  dist/release/Intent-Firefox.zip \
  --target "$LAUNCH_COMMIT" --draft \
  --title "Intent $LAUNCH_VERSION" \
  --notes 'Verified launch channel; experimental T website adder excluded. See the release QA record for acceptance evidence.'
```

If Chrome was independently approved and both extra kits passed verification:

```bash
gh release upload "$LAUNCH_TAG" \
  dist/release/Intent-Chrome.zip dist/release/Intent-Both.zip
```

Download the draft's uploaded artifacts into a separate temporary directory, compare their SHA-256 hashes with the local verified files, and verify the release manifest and ZIP contents. Record the release tag, commit, build, signing Team ID, and actual extension versions in the QA note. Do not replace assets after a tag has been accepted; use a new version for a changed build.

Only after those checks and installed/profile acceptance:

```bash
gh release edit "$LAUNCH_TAG" --draft=false
```

In the separate `intent-waitlist` website checkout, replace `PINNED_LAUNCH_RELEASE = null` in `lib/release-catalog.mjs` only after auditing that exact published release. Keep the real manifest fields, including repository, version, `launch-<version>` tag, compiled channel, T disabled, notarization, Team ID, and exact signed Firefox version. Add `bundles.firefox` with the immutable `Intent-Firefox.zip` URL and its actual lowercase SHA-256. For an approved matching Chrome release, also retain the verified Chrome approval/version/store URL and add `bundles.chrome` and `bundles.both` with their corresponding exact filenames and actual hashes.

The catalog's version constants must match the version independently tested for that release. Its validator checks trusted metadata, URLs, and hash format; it does not notarize or download the remote bytes itself. Verify those before pinning. Update the pending-catalog fixture deliberately when a qualifying release is pinned, then run the website checks from that checkout:

```bash
node --test tests/*.test.mjs
npm run build
```

Deploy the verified website package through its existing Sites workflow and check the live browser download routes. A Firefox-only pin enables Firefox; Chrome and both remain unavailable until exact Chrome approval and the matching kits qualify. Recommend both when both are available. A pending store review must not expose a development ZIP as a consumer Chrome install.

The catalog is intentionally empty until a qualifying release exists, and no build or `main` push enables it automatically. The owner-only `/download/test` page has no development binary links. Never fall back to `releases/latest`, `intent-beta-feed`, or an old release when the catalog fails validation.

The current work does not change GitHub workflows. A legacy beta workflow or a `main` push is not launch promotion. App automatic update checks and automatic download are disabled in current launch manifests; the reserved launch feed is separate from the legacy beta feed and must be published and tested explicitly before enabling updates. Development builds reject public-channel updates.
