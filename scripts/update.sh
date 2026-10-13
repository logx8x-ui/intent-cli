#!/usr/bin/env bash
set -euo pipefail

# Private testers update through the same invite-only, version-pinned installer.
# Never fetch and execute a moving main-branch installer or choose an arbitrary
# "latest" release while the app and Browser Guard must be qualified together.
echo 'To update Intent, download the current installer from your private tester link.'
echo 'Finish your intention and close Intent before opening that installer. Your intentions and settings are preserved.'
exit 0
