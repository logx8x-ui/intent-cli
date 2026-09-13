# Intent 0.9.2 tester build

This build includes the current Cmd+G desktop picker, app and browser-tab selection,
Allow/Block mode, blur, first-intention onboarding, and restriction/friction panels.
It is an unsigned, unnotarized prerelease for testing, not a production release.
Supports Apple Silicon and Intel Macs running macOS 13 or newer.

## Install

1. Download `Intent-Tester-unsigned.dmg` from this prerelease's Assets.
2. Open it and run `Install Intent.pkg`. This installs the app and browser bridge.
3. If macOS blocks the installer, use System Settings → Privacy & Security →
   Open Anyway after attempting to open it. Approve only this Intent installer;
   do not disable Gatekeeper globally. Apple explains this at
   https://support.apple.com/en-us/102445.
4. Open Intent from Applications. If macOS separately blocks the app, use the
   same per-app Open Anyway approval. Continue as a guest; Google sign-in is not
   ready for this test. Grant the permissions Intent requests for the features
   you use, including Accessibility and Screen Recording for window previews.
5. Install the matching browser extension below before selecting browser tabs.
6. Press Command+G, select your work apps/tabs, and start. `/` switches Allow/Block.

The installer preserves saved intentions and preferences. Close any older Intent
copy before installing. This prerelease does not enable automatic beta updates.

## Chrome

Download `Intent-Chrome-Extension.zip`, extract it, and keep the extracted folder.
Open `chrome://extensions`, enable Developer mode, choose Load unpacked, and
select the folder containing `manifest.json`. If an older unpacked copy is already
installed, remove that copy first. The included Browser Guard version is 0.2.8.

## Firefox

Download `Intent-Firefox-Extension.zip` and extract it. Open
`about:debugging#/runtime/this-firefox`, choose Load Temporary Add-on, and select
the extracted `manifest.json`. The included Browser Guard version is 0.2.8.

**Firefox removes this temporary add-on when Firefox quits. Reload it after each
restart.** This ZIP is not a permanently installable signed XPI. Do not use the
older 0.2.5 extension assets from the old stable release for this test.

## First test

Start with a one-minute session and leave “Lock until it ends” off. Check that
selected apps/tabs remain usable and that finishing returns normal control.
The emergency release shortcut is Command+Control+Option+Escape.
Avoid Zero Drift for this first check. If anything fails, report the browser,
what you selected, and what happened; do not repeatedly try a locking mode.

## What is not included

The proposed simplification of controls has not been implemented. Google login,
permanent Firefox installation, Apple notarization, and production auto-updates
are not being claimed as working by this prerelease.
