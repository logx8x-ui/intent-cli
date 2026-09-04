# Intent

Intent is a macOS focus app that opens one chosen set of apps and websites, then keeps everything else out until you finish.

Built with Codex during OpenAI Build Week. GPT-5.6 powers the optional intention
builder while every generated app and website remains editable before import.

## Download

> **Release safety:** public binary installation is enabled only for a Developer ID
> signed and Apple-notarized release. Intent deliberately refuses unsigned GitHub
> binaries. The current source is available now; the next binary release requires
> the Apple signing credentials described in [Releasing](docs/RELEASING.md).

### One-command install

Paste this into Terminal, or give the repository link to Codex and say **install the latest Intent release**:

```zsh
curl -fsSL https://raw.githubusercontent.com/logx8x-ui/intent-cli/main/install.sh | bash
```

macOS asks once for administrator approval, installs the latest published release, and opens Intent. Future updates appear inside Intent at the bottom left; installing an update keeps every intention, schedule, background, and setting.

The command downloads a small release manifest first, checks the DMG checksum,
Apple notarization ticket, installer signature, and publisher Team ID, and only
then asks for installation approval. It never clones the repository and does not
require Xcode or Command Line Tools.

These are the only three manual downloads:

| Download | Use it for |
| --- | --- |
| **[Intent for Mac](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent.dmg)** | The main app. Requires macOS 13 or newer. |
| **[Firefox Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent-Firefox-Extension.xpi)** | Website restrictions in Firefox. Mozilla-signed for normal installs. |
| **[Chrome Browser Guard](https://github.com/logx8x-ui/intent-cli/releases/latest/download/Intent-Chrome-Extension.zip)** | Website restrictions in Chrome. |

Install the Mac app first, then install the Browser Guard for the browser you use. Leave its toolbar switch on: it only blocks pages while an intention is running, while local domain history can also improve Purpose Mode and Recording Mode suggestions.

### Firefox

1. Open the Firefox Browser Guard `.xpi` download in Firefox.
2. Accept the installation prompt.
3. Keep the Intent Browser Guard toolbar switch on.

Tester releases use Mozilla's unlisted signing, so Browser Guard remains installed after Firefox restarts even before a public Add-ons listing exists.

### Chrome

1. Unzip the Chrome Browser Guard download.
2. Open `chrome://extensions` in Chrome.
3. Turn on **Developer mode**, choose **Load unpacked**, and select the unzipped folder.

## Use Intent

New installs open to a blank canvas with **Welcome to my desktop** and a short guide.

On first launch, choose **Continue as guest**, **Continue with Google**, or use
an email and password. Guest mode includes the full Intent experience and saves
only on that Mac. An account keeps each device on the same private workspace;
a brand-new account always starts with zero intentions. See [Intent Accounts](docs/ACCOUNTS.md).

- Click an intention to run it.
- Press `~` to show or hide Intent, or change that shortcut in Settings.
- Press `Tab` to edit, then `I`, `R`, or `F` to add an intention, restriction, or friction.
- Pinch to zoom and use two fingers to pan.
- Press `Cmd+Shift+M` to finish an active intention.
- Press `Shift+W` for whitelist Purpose Mode or `Shift+B` for blacklist Purpose Mode while you are not typing.
- Whitelist intentions allow only their selected resources. Blacklist intentions block their selected apps and browser websites while leaving everything else available.
- Open **Recording Mode** from the record-circle control to learn aggregate app and browser-domain usage for 24 hours, one week, or until you stop it, then review up to seven local Allow Only suggestions.
- Add a **Timer** restriction to end a session automatically.
- Add a **Cooldown** restriction to prevent restarting an intention for a chosen period after it ends.

### Build with AI

The AI prompt bar at the bottom asks what intention you want to build, moves to a dedicated AI draft workspace, and creates one editable intention with the requested apps, websites, restrictions, and friction. Choose **Finalise**, then click the main canvas to place it. Manual creation with `I` still works exactly as before.

Draft history is saved locally under `~/.intent/ai-history.json`. Open the clock control in the AI workspace to resume or delete drafts. Type `@` to mention an existing intention by stable id so Finalise updates that intention in place.

No API key is required. Intent sends the description you submit plus installed app names and bundle identifiers to its hosted AI service. Generated apps and sites are checked locally before import, and nothing starts until you review and finalise the draft. Calendar contents are never included in AI requests.

### Scheduler and calendars

The scheduler page keeps local Intent schedules in `~/.intent/schedules.json` and can start intentions when they become due. Optional Apple Calendar and Google Calendar connections appear under **Calendars** in the scheduler header. Local scheduling always works without an account, permission, or network. See [Google Calendar setup](docs/GOOGLE_CALENDAR.md) for the optional OAuth client ID.

The first session asks once for macOS Accessibility permission so Intent can enforce app restrictions.

Recording Mode does not record the screen. It stores only aggregate app time and normalized browser-domain counts under `~/.intent/activity-recording.json`, never sends that data to AI, and requires no Screen Recording permission. Browser domains are included only when Browser Guard is enabled.

## Build From Source

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git
cd intent-cli
./scripts/install-dev.sh
```

Run the complete checks:

```zsh
npm install
npm test
```

Public DMGs must be signed with Apple Developer ID certificates and notarized. `scripts/build-release.sh` supports that process and refuses a public release when the required Apple credentials are missing.

For a local developer-only build:

```zsh
./scripts/build-local-release.sh
```

That produces `Intent-local-unsigned.dmg`, which is intentionally unsuitable for
sharing or publishing.

## Uninstall

Remove the app while keeping your intentions and settings:

```zsh
curl -fsSL https://raw.githubusercontent.com/logx8x-ui/intent-cli/main/uninstall.sh | bash
```

Add `--delete-data` when running a downloaded copy of `uninstall.sh` to also
remove the local data under `~/.intent`.

Intent is a personal focus tool, not security software. See [Privacy](PRIVACY.md)
for its local-first storage and optional account-sync behavior.

## OpenAI Build Week

Intent began as a personal CLI prototype. During Build Week it became the native
spatial app in this repository: graph editing, browser guards, scheduler,
focused switchers, timers and cooldowns, release packaging, and the hosted AI
builder. The full account of how Codex and GPT-5.6 contributed, including dated
commit evidence and key design decisions, is in [BUILD_WEEK.md](BUILD_WEEK.md).

The source is available under the [MIT License](LICENSE).
