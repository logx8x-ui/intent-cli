# Intent 0.9.3 beta setup

Download the [current tester](https://github.com/logx8x-ui/intent-cli/releases/download/intent-beta-feed/Intent-Tester-Mac.zip). It supports Apple Silicon Macs (M1 or newer) running macOS 13+. This beta is not Apple notarized and does not support Intel Macs.

1. Extract the ZIP and open **Install Intent.command**. It installs Intent into Applications and opens it. Updating an existing installation preserves intentions and preferences. A fresh installation through this installer after removing Intent starts onboarding with empty local data.
2. If macOS blocks the installer or app, follow [Apple’s per-app approval instructions](https://support.apple.com/en-us/102445). Do not disable Gatekeeper globally.
3. Continue as a guest while email delivery and account verification are being validated. Setup guides you through Accessibility and Screen Recording, then browser connection.
4. For **Chrome**, use Intent’s browser setup to open the persistent Browser Guard folder. In chrome://extensions, enable Developer mode and choose Load unpacked. Replace an old unpacked Browser Guard copy with this one. The included version is 0.2.9.
5. For **Firefox**, use Intent’s browser setup to open its manifest, then Load Temporary Add-on in about:debugging#/runtime/this-firefox. **Reload the temporary add-on after every Firefox restart.** Do not use the old stable 0.2.5 extension.
6. Press **Command+G**, select work apps/tabs and start a short intention. `/` switches between allowing selected resources and blocking selected resources.

## Updates

Older testers need this one manual installation to gain the new Sparkle updater. Afterward, Intent checks for signed releases each hour and downloads updates in the background. Finish your intention before restarting to apply an update. The download/install/relaunch path was verified on Logan’s Mac with saved intention data preserved.

Every push to main now runs the tests, builds and publishes a signed beta if checks pass; the complete CI-to-installed-app path was verified. A failed build does not replace the working release. Email signup still requires an email-sending provider: the current Supabase default sender cannot email ordinary testers, so use guest mode until that service is connected.

## First test

Start with a one-minute session and leave “Lock until it ends” off. Check that selected apps/tabs remain usable and finishing restores normal control. The emergency release shortcut is **Command+Control+Option+Escape**. Avoid Zero Drift for this first check. Report the app version, browser, selection and what happened if anything fails.
