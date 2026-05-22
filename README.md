# Intent

Intent is a macOS focus tool for running saved intentions: focused sessions that allow only selected apps and browser targets until you exit with `Cmd+Shift+M`.

The repo now has two entry points:

- `Intent`: the original CLI, kept for quick launching and testing.
- `intent-app`: the native macOS builder for creating, editing, and starting intentions.

Current tasks:

- Shallow: Imessages
- Shallow: Instagram replies
- Shallow: Emails
- Deep: Data science

## Requirements

- macOS 13 or newer
- Xcode Command Line Tools
- Firefox for browser-based tasks
- RStudio, Spotify, RemNote, and Codex for the current Data science deep-work mode

Install Xcode Command Line Tools if needed:

```zsh
xcode-select --install
```

## Install

Clone this repo, then run:

```zsh
./scripts/install.sh
```

Then start the desktop app:

```zsh
intent-app
```

You can also open `Intent` from `~/Applications/Intent.app`; after Spotlight indexes it, it should appear in Spotlight search as `Intent`.

Or start the CLI:

```zsh
Intent
```

The installer also installs the Firefox native messaging host that lets the browser extension read the active Intent rules.

To enable Firefox tab and URL blocking during browser intentions:

1. Install the Intent Browser Guard Firefox extension.
2. Click the Intent Browser Guard toolbar icon in Firefox.
3. Keep the switch on.

During development, load it locally:

1. Open Firefox.
2. Go to `about:debugging#/runtime/this-firefox`.
3. Click `Load Temporary Add-on...`.
4. Choose `firefox-extension/manifest.json` from this repo.

For the unlisted beta, build and sign the extension with Mozilla Add-ons:

```zsh
npm install
./scripts/build-firefox-extension.sh
export AMO_JWT_ISSUER='user:...'
export AMO_JWT_SECRET='...'
./scripts/sign-firefox-extension.sh
```

`scripts/sign-firefox-extension.sh` signs through Mozilla's unlisted add-on flow. The signed `.xpi` is written to `dist/firefox/` and can be shared with testers without making the extension public on AMO. The final signing step needs credentials from the Intent Mozilla Add-ons developer account.
Intent now refuses to start Firefox-locked intentions when that browser guard is not connected, instead of silently running without tab protection.

The first lock session may need macOS permissions:

- System Settings > Privacy & Security > Accessibility
- Enable your terminal app for CLI sessions, or `IntentApp` for desktop-app sessions
- If prompted, also enable Input Monitoring for the app you are using to start sessions

## Update

From the cloned repo:

```zsh
./scripts/update.sh
```

That pulls the latest GitHub version and reinstalls the CLI, desktop app, and Firefox native host.

## Friend Install Command

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git ~/intent && ~/intent/scripts/install.sh
```

Then they can run:

```zsh
intent-app
```

Or open `~/Applications/Intent.app`.

They should also install Intent Browser Guard in Firefox and keep its toolbar switch on. Until the Mozilla public listing is approved, they can load the development extension from `~/intent/firefox-extension/manifest.json` using `about:debugging#/runtime/this-firefox`.

After that, friends can update with:

```zsh
~/intent/scripts/update.sh
```

## Notes

Intent uses macOS Accessibility/event taps to block common app-switching and browser-switching escape paths during a focus session. It is a personal focus tool, not security software.
