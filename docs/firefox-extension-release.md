# Intent Browser Guard Release

Intent Browser Guard is the Firefox extension that enforces browser-level Intent restrictions:

- block switching to tabs whose URL is not allowed
- block navigation to unallowed URLs
- block new tabs unless the active intention allows Google search tabs
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

## Build The XPI

```zsh
./scripts/build-firefox-extension.sh
```

The unsigned package is written to `dist/firefox/`.

## Public Mozilla Add-ons Signing

Firefox requires most normal-release extensions to be digitally signed by Mozilla.

1. Create or open the Intent Mozilla Add-ons developer account.
2. Create API credentials at `https://addons.mozilla.org/en-US/developers/addon/api/key/`.
3. Export the credentials:

```zsh
export AMO_JWT_ISSUER='user:...'
export AMO_JWT_SECRET='...'
```

4. Submit/sign the listed public release:

```zsh
./scripts/sign-firefox-extension.sh
```

The script uses `web-ext sign --channel=listed` and `amo-listing.json`.

## Current Public Links

- Repository: `https://github.com/logx8x-ui/intent-cli`
- Mozilla Add-ons listing: pending first Mozilla submission/approval
