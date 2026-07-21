# Intent

Intent is a macOS focus app that opens one chosen set of apps and websites, then keeps everything else out until you finish.

## Download

These are the only three downloads most people need:

| Download | Use it for |
| --- | --- |
| **[Intent for Mac](https://github.com/logx8x-ui/intent-cli/releases/download/v0.4.0/Intent-0.4.0.dmg)** | The main app. Requires macOS 13 or newer. |
| **[Firefox Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/download/v0.4.0/intent_browser_guard-0.1.6.zip)** | Website restrictions in Firefox. |
| **[Chrome Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/download/v0.4.0/intent-browser-guard-chrome-0.1.2.zip)** | Website restrictions in Chrome. |

Install the Mac app first, then install the Browser Guard for the browser you use. Leave its toolbar switch on: it only enforces rules while an intention is running.

### Firefox

1. Unzip `Intent-Firefox-Extension.zip`.
2. Open `about:debugging#/runtime/this-firefox` in Firefox.
3. Choose **Load Temporary Add-on** and select `manifest.json` from the unzipped folder.

Firefox removes temporary add-ons after a restart. A permanent Mozilla Add-ons listing is planned.

### Chrome

1. Unzip `Intent-Chrome-Extension.zip`.
2. Open `chrome://extensions` in Chrome.
3. Turn on **Developer mode**, choose **Load unpacked**, and select the unzipped folder.

## Use Intent

New installs open to a blank canvas with **Welcome to my desktop** and a short guide.

- Click an intention to run it.
- Press `~` to show or hide Intent, or change that shortcut in Settings.
- Swipe with three fingers to move between the intentions desktop and scheduler.
- Press `E` to edit, then `I`, `R`, or `F` to add an intention, restriction, or friction.
- Pinch to zoom and use two fingers to pan.
- Press `Cmd+Shift+M` to finish an active intention.
- Add a **Timer** restriction to end a session automatically.
- Add a **Cooldown** restriction to prevent restarting an intention for a chosen period after it ends.

### Build with AI

The AI prompt bar at the bottom asks what intention you want to build, suggests a small set of focused intentions, and lets you check every app and website before anything is added. Manual creation with `I` still works exactly as before.

No API key is required. Intent sends the description you type plus installed app names and bundle identifiers to its hosted AI service only after you choose **Suggest intentions**. Generated apps and sites are checked locally before import, and nothing starts until you review it.

The first session asks once for macOS Accessibility permission so Intent can enforce app restrictions.

## Build From Source

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git
cd intent-cli
./scripts/install.sh
```

Run the complete checks:

```zsh
swift run IntentCoreSpec
npm install
npm run test:extensions
npm run extension:lint
```

Public DMGs must be signed with Apple Developer ID certificates and notarized. `scripts/build-release.sh` supports that process and refuses a public release when the required Apple credentials are missing.

Intent is a personal focus tool, not security software. See [Privacy](PRIVACY.md) for its local-only data behavior.
