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

For every Intent change, follow `docs/session-ui-regression-contract.md`. Before
editing, record the reported sequence and adjacent working behaviours; run
`npm run qa:plan` to see the change-impact map. Add a behavioural regression for
the real broken surface, not a nearby substitute (a selected overview thumbnail
does **not** prove a green outline on the actual Firefox tab/window in DBT).

After edits settle, run `npm run test:changed`. For an already committed change,
pass `-- --base <pre-change-commit>`; a clean `HEAD` diff cannot certify that
commit. The gate runs existing suites serially and rejects source drift. Do not
weaken/remove neighbouring regressions to make a fix pass. Keep shared input and
completion ownership in one place. Never run bare lifecycle spec executables:
use `test:session-ui`, `test:swift`, or `scripts/run-isolated-spec.sh` so QA cannot
read the daily recovery ledger. Coordinate shared build and desktop ownership.

Protect Logan's physically confirmed Caps Lock + backtick Run and backtick-number
toggles (baseline `f969241`, October 5, 2026) when touching selection or input.
DBT Run preserves the tab/native window where Run is invoked. Every finish mode
preserves the exact window (and browser tab) where the user finishes, not the
session's starting window or another window of the same app. As requested on
October 9, restore all visibility changes owned by Intent at finish, including
older deferred entries; do not leave those windows minimized in the Dock.
Windows the user had already hidden or minimized stay that way. Restoration must
preserve the current foreground window and must not force a Space change.

A passing isolated gate is not physical-key, actual-outline, foreground-focus,
installed-build or browser-profile acceptance. Install matching authorized
development components, check the exact profile/extension and installed UUID,
and exercise both the changed flow and adjacent protected flows. Report each
unverified item plainly; never turn a prior build's user confirmation into a
current-build pass. Record reproduction, cause, regression, source identity and
acceptance in a focused `docs/qa/` note. Preserve user data throughout QA. These
are standing requirements for future work, not a guarantee that bugs are impossible.
