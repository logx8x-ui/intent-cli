# Installing Intent

For Intent feature and fix requests, Logan has explicitly authorized installing
the development build and matching browser components, then testing the result
live. Run `scripts/install-dev.sh` as part of that workflow without asking for
development-install confirmation again. Preserve user data and unrelated work.
This standing authorization was confirmed on September 9, 2026.

The published-release rule below applies to standalone install/update requests,
not to installing a feature or fix that Logan asked you to implement.

When a user asks to install or update Intent from this repository, always run:

```bash
./install.sh
```

This script downloads and installs the newest published GitHub release. Do not build the checked-out source and do not run `scripts/install-dev.sh` unless the user explicitly asks for a development build.

After installation, confirm `/Applications/Intent.app` exists and open it. The installer preserves the user's data in `~/.intent` and their macOS preferences.

# Session UI reliability

For shortcut, timer/checklist HUD or session-completion changes, follow
`docs/session-ui-regression-contract.md` and run `npm run test:session-ui` after
edits settle. Keep shared input and completion ownership in one place; add a
behavioural regression for the reported sequence. A passing isolated gate is not
physical-key, foreground-focus, installed-build or browser-profile acceptance.
Record those checks separately and preserve user data throughout QA.
