# Intent

Intent is a macOS focus app that opens one chosen set of apps and websites, then keeps everything else out until you finish.

Built with Codex during OpenAI Build Week. GPT-5.6 powers the optional intention
builder while every generated app and website remains editable before import.

## Download

### One-command install

Paste this into Terminal, or give the repository link to Codex and say **install the latest Intent release**:

```zsh
curl -fsSL https://raw.githubusercontent.com/logx8x-ui/intent-cli/main/install.sh | bash
```

macOS asks once for administrator approval, installs the latest published release, and opens Intent. Future updates appear inside Intent at the bottom left; installing an update keeps every intention, schedule, background, and setting.

These are the only three manual downloads:

| Download | Use it for |
| --- | --- |
| **[Intent for Mac](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent.dmg)** | The main app. Requires macOS 13 or newer. |
| **[Firefox Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent-Firefox-Extension.zip)** | Website restrictions in Firefox. |
| **[Chrome Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent-Chrome-Extension.zip)** | Website restrictions in Chrome. |

Install the Mac app first, then install the Browser Guard for the browser you use. Leave its toolbar switch on: it only enforces rules while an intention is running.

### Firefox

1. Unzip the Firefox Browser Guard download.
2. Open `about:debugging#/runtime/this-firefox` in Firefox.
3. Choose **Load Temporary Add-on** and select `manifest.json` from the unzipped folder.

Firefox removes temporary add-ons after a restart. A permanent Mozilla Add-ons listing is planned.

### Chrome

1. Unzip the Chrome Browser Guard download.
2. Open `chrome://extensions` in Chrome.
3. Turn on **Developer mode**, choose **Load unpacked**, and select the unzipped folder.

## Use Intent

New installs open to a blank canvas with **Welcome to my desktop** and a short guide.

- Click an intention to run it.
- Press `~` to show or hide Intent, or change that shortcut in Settings.
- Press `Tab` to edit, then `I`, `R`, or `F` to add an intention, restriction, or friction.
- Pinch to zoom and use two fingers to pan.
- Press `Cmd+Shift+M` to finish an active intention.
- Add a **Timer** restriction to end a session automatically.
- Add a **Cooldown** restriction to prevent restarting an intention for a chosen period after it ends.

### Build with AI

The AI prompt bar at the bottom asks what intention you want to build, moves to a dedicated AI draft workspace, and creates one editable intention with the requested apps, websites, restrictions, and friction. Choose **Finalise**, then click the main canvas to place it. Manual creation with `I` still works exactly as before.

No API key is required. Intent sends the description you submit plus installed app names and bundle identifiers to its hosted AI service. Generated apps and sites are checked locally before import, and nothing starts until you review and finalise the draft.

The first session asks once for macOS Accessibility permission so Intent can enforce app restrictions.

## Build From Source

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git
cd intent-cli
./scripts/install-dev.sh
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

## OpenAI Build Week

Intent began as a personal CLI prototype. During Build Week it became the native
spatial app in this repository: graph editing, browser guards, scheduler,
focused switchers, timers and cooldowns, release packaging, and the hosted AI
builder. The full account of how Codex and GPT-5.6 contributed, including dated
commit evidence and key design decisions, is in [BUILD_WEEK.md](BUILD_WEEK.md).

The source is available under the [MIT License](LICENSE).
