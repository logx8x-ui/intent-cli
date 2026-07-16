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
- Firefox or Google Chrome for browser-based tasks
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
- In edit mode, drag existing shapes to move them.
- Creation is keyboard-only: press `I` to create an intention at the pointer, `R` to attach a restriction to the selected intention, or `F` to attach a friction.
- An intention editor also has direct circle and triangle buttons for attaching a restriction or friction.
- Press `S` or click `Save (S)` to close the selected editor, Delete or `X` to remove the selected shape, and `Cmd+Z` to undo the latest canvas change.
- Pinch to zoom, use two fingers or drag empty space to pan, or use the bottom-right zoom and fit controls.
- Intention edits autosave. Clicking empty canvas saves and closes the selected shape's settings menu.

Every allowed app and website starts automatically. Attach a `Don't start up` restriction to keep selected resources closed initially while still allowing them during the intention. Multiple friction triangles run from the highest shape on the canvas to the lowest.

During an active intention, Intent replaces `Cmd+Tab` with an app-level switcher containing only currently running allowed apps. Cmd+grave continues to switch windows inside the selected app, and `Cmd+Shift+M` ends the intention and restores the Intent overlay.

Or start the CLI:

```zsh
Intent
```

The installer also installs the Firefox and Chrome native messaging hosts that let each Browser Guard read only its own active Intent rules.
Both guards always permit creating a blank tab. Without the browser-search restriction, submitting from that tab closes it; with the restriction, Google search results work while unallowed websites remain blocked.

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
Intent refuses to start Firefox or Chrome intentions when that browser's guard is disconnected or switched off, instead of silently running without tab protection. Other browsers remain unsupported for enforceable tab and URL restrictions.

To test Intent Browser Guard in Chrome:

1. Run `./scripts/install.sh` so Chrome can reach the native host.
2. Open `chrome://extensions`.
3. Enable Developer mode.
4. Click `Load unpacked` and choose the repo's `chrome-extension` folder.
5. Pin Intent Browser Guard and leave its switch on. "Listening" does not block normal browsing; rules activate only while an intention is running.

Build the Chrome Web Store package with:

```zsh
npm run extension:build:chrome
```

The upload-ready ZIP is written to `dist/chrome/`. Chrome Web Store submission is a later release step; local unpacked testing uses the same extension code and persistent toggle.

The first lock session may need macOS permissions:

- System Settings > Privacy & Security > Accessibility
- Enable your terminal app for CLI sessions, or `IntentApp` for desktop-app sessions
- If prompted, also enable Input Monitoring for the app you are using to start sessions

## Update

From the cloned repo:

```zsh
./scripts/update.sh
```

That pulls the latest GitHub version and reinstalls the CLI, desktop app, and both browser native hosts.

## Friend Install Command

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git ~/intent && ~/intent/scripts/install.sh
```

Then they can start the menu-bar app:

```zsh
intent-app
```

For the desktop experience, open `~/Applications/Intent.app`, then use the menu-bar icon or press `~`.

They should also install Intent Browser Guard in the browser used by their intentions and keep its toolbar switch on. Firefox can use the signed beta or temporary development extension; Chrome can load `~/intent/chrome-extension` as an unpacked extension during beta testing.

After that, friends can update with:

```zsh
~/intent/scripts/update.sh
```

## Notes

Intent uses macOS Accessibility/event taps to block common app-switching and browser-switching escape paths during a focus session. It is a personal focus tool, not security software.
