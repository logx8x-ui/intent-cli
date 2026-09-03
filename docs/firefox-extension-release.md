# Intent Browser Guard Release

Intent Browser Guard is the Firefox extension that enforces browser-level Intent restrictions:

- block switching to tabs whose URL is not allowed
- block navigation to unallowed URLs
- always allow creating a blank tab
- close a newly created tab when it is submitted without the browser-search restriction
- allow Google search result pages without allowing click-throughs to blocked websites

The extension has a persistent toolbar switch. When the switch is on, Firefox follows the active rules written by the Intent macOS app. When it is off, Firefox ignores those rules.

## Local Development

```zsh
npm install
npm run test:firefox
npm run extension:lint
```

To load it locally:

1. Open Firefox.
2. Go to `about:debugging#/runtime/this-firefox`.
3. Click `Load Temporary Add-on...`.
4. Choose `firefox-extension/manifest.json`.

## Build The Unsigned Development Package

```zsh
./scripts/build-firefox-extension.sh
```

The unsigned development package is written to `dist/firefox/`. It is useful only for local checks; tester and public releases must use Mozilla signing.

## Unlisted Beta Signing

Firefox requires most normal-release extensions to be digitally signed by Mozilla.

Use unlisted signing for beta builds. Unlisted builds are signed by Mozilla, install normally in Firefox, and can be shared with testers, but they are not searchable on the public Firefox Add-ons store.

1. Create or open the Intent Mozilla Add-ons developer account.
2. Create API credentials at `https://addons.mozilla.org/en-US/developers/addon/api/key/`.
3. Export the credentials:

```zsh
export AMO_JWT_ISSUER='user:...'
export AMO_JWT_SECRET='...'
```

4. Sign the unlisted beta:

```zsh
./scripts/sign-firefox-extension.sh
```

The script uses `web-ext sign --channel=unlisted`. The signed `.xpi` is written to `dist/firefox/`.

## Installing The Signed Beta

1. Open Firefox.
2. Open the signed `.xpi` from `dist/firefox/`.
3. Accept the Firefox install prompt.
4. Click the Intent Browser Guard toolbar icon and keep the switch on.
5. Start an Intent session that uses Firefox.

Public Intent release builds refuse to complete without AMO signing credentials and publish the signed file as `Intent-Firefox-Extension.xpi`. This prevents testers from silently keeping an old temporary or previously signed guard while running a newer app.

The Intent desktop app must still be installed because the extension reads active session rules from Intent through native messaging.

## Later Public Release

When Intent is ready for public users, run the listed signing flow:

```zsh
npm run extension:sign:listed
```

Listed signing uses `amo-listing.json` and submits the add-on for a public AMO listing.

## Current Public Links

- Repository: `https://github.com/logx8x-ui/intent-cli`
- Mozilla Add-ons listing: pending future public submission
