# Installing Intent

When a user asks to install or update Intent from this repository, always run:

```bash
./install.sh
```

This script downloads and installs the newest published GitHub release. Do not build the checked-out source and do not run `scripts/install-dev.sh` unless the user explicitly asks for a development build.

After installation, confirm `/Applications/Intent.app` exists and open it. The installer preserves the user's data in `~/.intent` and their macOS preferences.
