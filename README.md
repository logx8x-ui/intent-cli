# Intent

Intent is a macOS focus tool for running saved intentions: focused sessions that allow only selected apps and browser targets until you exit with `Cmd+Shift+M`.

The repo has two entry points:

- `Intent`: the original CLI, kept for quick launching and testing.
- `intent-app`: the native macOS menu-bar app and spatial intention canvas.

Default intentions:

- Imessages
- Instagram replies
- Emails
- Data science

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

Then start the menu-bar app:

```zsh
intent-app
```

You can also open `Intent` from `~/Applications/Intent.app`. Intent runs in the menu bar and intentionally does not keep a Dock icon.
The installer registers Intent to start once at each macOS login, so the global `~` shortcut is available without opening a normal window first.

## Using the canvas

- Press `~` anywhere on the Mac to show or hide the near-full-screen Intent overlay.
- Click an intention once to run it.
- Press `E` to enter or leave edit mode. The blue perimeter indicates that shapes can be changed.
- In edit mode, drag shapes to move them. Drag from an intention's edge to attach a restriction or friction.
- Press `I` to create an intention at the pointer, `R` to attach a restriction, or `F` to attach a friction.
- Pinch to zoom, drag empty canvas space to pan, or use the bottom-right zoom and fit controls.
- Intention edits autosave. Clicking empty canvas does not close the selected shape's settings menu.

Every allowed app and website starts automatically. Attach a `Don't start up` restriction to keep selected resources closed initially while still allowing them during the intention. Multiple friction triangles run from the highest shape on the canvas to the lowest.

During an active intention, Intent replaces `Cmd+Tab` with an app-level switcher containing only currently running allowed apps. Cmd+grave continues to switch windows inside the selected app, and `Cmd+Shift+M` ends the intention and restores the Intent overlay.

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
Intent refuses to start Firefox intentions when Browser Guard is not connected, instead of silently running without tab protection. Firefox is the currently supported browser for enforceable tab and URL restrictions; Intent refuses to start browser intentions using unsupported browsers rather than presenting a false lock.

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

Then they can start the menu-bar app:

```zsh
intent-app
```

For the desktop experience, open `~/Applications/Intent.app`, then use the menu-bar icon or press `~`.

They should also install Intent Browser Guard in Firefox and keep its toolbar switch on. Until the Mozilla public listing is approved, they can load the development extension from `~/intent/firefox-extension/manifest.json` using `about:debugging#/runtime/this-firefox`.

After that, friends can update with:

```zsh
~/intent/scripts/update.sh
```

## Notes

Intent uses macOS Accessibility/event taps to block common app-switching and browser-switching escape paths during a focus session. It is a personal focus tool, not security software.
