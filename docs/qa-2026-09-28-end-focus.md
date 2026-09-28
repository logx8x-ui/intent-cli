# Preserve the foreground workspace when an intention ends

The app already disabled `restorePreviousApplicationOnStop`, but native unhide/deminiaturize calls and later browser-tab recovery could still raise other windows. All native exit paths now start a short recovery transaction before changing visibility, capturing the app and AX window current at teardown, not the session-start app.

The transaction repairs focus after each owned restoration and watches delayed recovery for up to five seconds. Only the original app or a restoring app/browser can trigger correction. Real keyboard/mouse input, an unrelated app activation, a new session, a closed/minimized original window, or the deadline cancels it. It never launches applications, unhides the focus target, or activates all its windows.

Validation:
- IntentCoreSpec passed, including restoration-origin, same-app, delayed-browser, real-input cancellation and unrelated-app cancellation regression cases.
- Optimized Intent, IntentApp and IntentNativeHost builds passed.
- Development installation at ~/Applications/Intent.app completed using system Python (Homebrew Python's expat linkage was broken); code signature verified.
- Installed UI: temporary blacklist session hid Spotify; normal End control ended the session and hidden-workspace ownership returned from one entry to zero.
- Synthetic Shift+backtick did not trigger the global hotkey and is not counted as a hotkey acceptance pass.
- Physical foreground stability for hotkey, timer/checklist expiry, multiple browser windows and Spaces remains unverified. The shared restoration path covers these exits in source; this is not a claim that all live combinations passed.

No extension code or public releases changed. Existing intentions and settings preserved; a temporary session remains in recent history.
