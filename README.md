# Intent

Intent is a small macOS CLI for choosing an intentional focus session before using your computer.

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

Then start Intent:

```zsh
Intent
```

The first lock session may need macOS permissions:

- System Settings > Privacy & Security > Accessibility
- Enable your terminal app
- If prompted, also enable Input Monitoring for your terminal app

## Update

From the cloned repo:

```zsh
./scripts/update.sh
```

That pulls the latest GitHub version and reinstalls the CLI.

## Friend Install Command

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git ~/intent && ~/intent/scripts/install.sh
```

After that, friends can update with:

```zsh
~/intent/scripts/update.sh
```

## Notes

Intent uses macOS Accessibility/event taps to block common app-switching and browser-switching escape paths during a focus session. It is a personal focus tool, not security software.
