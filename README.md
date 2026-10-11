# Intent

Intent is a macOS focus app that opens one chosen set of apps and websites, then keeps everything else out until you finish.

Built with Codex during OpenAI Build Week. GPT-5.6 powers the optional intention
builder while every generated app and website remains editable before import.

## Download

Get the launch version from **[livewithintent.app/download](https://livewithintent.app/download)**, for macOS 13 or newer. Downloads stay unavailable until a tested, Apple-notarized release and its matching browser components pass the release checks; an unsigned beta or development build is never used as a fallback.

Choose Firefox, Chrome, or both when downloads become available. Install the Mac app, then use Intent's browser setup to choose the browser profiles you use, with **Select all** available. Google accounts belong to Chrome profiles; choosing a profile does not sign into an account or install an extension silently. Accept the browser's installation confirmation in each chosen profile and leave Browser Guard enabled.

Firefox uses a matching Mozilla-signed extension. Chrome uses the official Chrome Web Store listing only after its approved version matches the release. An unpacked Chrome extension is for local development.

Intent has two compiled channels in this repository: the owner's **development** build retains the experimental T website adder; the **launch** build excludes it. A tested commit is promoted manually to an immutable `launch-<version>` release. The launch download page does not track `latest` or the old beta feed. App update checks are currently disabled, so there is no promise of hourly or automatic app updates.

See [Launch and development channels](docs/launch-channels.md) for the build, promotion, and installation procedure, and [Browser extension distribution](docs/BROWSER_EXTENSION_DISTRIBUTION.md) for browser distribution requirements.

## Use Intent

New installs open to a blank canvas with **Welcome to my desktop** and a short guide.

On first launch, choose **Continue as guest**, **Continue with Google**, or use
an email and password. Guest mode includes the full Intent experience and saves
only on that Mac. An account keeps each device on the same private workspace;
a brand-new account always starts with zero intentions. See [Intent Accounts](docs/ACCOUNTS.md).

- Press backtick to open Mission Control. Name your intention, choose apps/windows or Chrome/Firefox tabs, then start.
- Double-tap backtick to mark the current tab or window. The same draft is available in Mission Control.
- Hold backtick and press a number from 1 to 6 to toggle that modification in your saved order. Keep holding backtick to toggle another.
- **Add as you go** is off by default and can only be chosen before starting. It allows ordinary app/tab opening and navigation; explicit blocks and always-banned apps still apply.
- **Stopwatch** counts elapsed time, including sleep, and does not lock finishing. Timer and Checklist keep their completion rules.
- To add an installed app, put one backtick before or after its search in Apple Spotlight and press Return on the app result. Intent requires the exact selected app URL from macOS accessibility; unsupported results leave the selection unchanged and show an explanation.
- Spotlight allow selections open in the background by default. Change this in Settings. Block selections never launch the blocked app.
- Use Settings for app defaults, visibility, shortcuts, account and login preferences. Saved intentions are available with Space in the workspace chooser.
- Command–G has no action in Intent. Opening the app or using the menu-bar icon goes straight to the workspace chooser (or the controls for a running session).
- Finish using your configured shortcut. A running timer or unfinished checklist keeps its existing finish requirements. Safety Stop remains available with Control–Option–Command–Escape.

### Legacy compatibility

The landing screen, canvas, AI builder and experimental navigation are no longer exposed in the normal app interface. Legacy stored data remains compatible. The following describes older implementations, not current workspace controls.

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
