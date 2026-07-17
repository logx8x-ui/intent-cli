# Intent

Intent is a macOS focus app that lets you choose one intention, opens its allowed apps and websites, and keeps everything else out until you finish.

## Download

1. Open [GitHub Releases](https://github.com/logx8x-ui/intent-cli/releases/latest).
2. Download `Intent-0.4.0.dmg`.
3. Open the DMG and double-click `Install Intent.pkg`.
4. If macOS blocks it, Control-click the package, choose **Open**, then confirm.
5. Look for the Intent scope icon in the menu bar, or press `~`.

Intent currently requires macOS 13 or newer. This beta is not yet Apple-notarized, which is why macOS shows the one-time warning in step 4.

## Browser Guard

Install the companion for the browser used by your intentions, then leave its toolbar switch on. The guard does nothing when no intention is running.

- **Firefox:** public Mozilla Add-ons listing is pending review. The temporary developer fallback is included in the DMG until approval.
- **Chrome:** public Chrome Web Store listing is pending review. The developer fallback ZIP is included in the DMG until approval.

Developer fallback for Chrome:

1. Unzip `Chrome - developer fallback.zip` from the DMG.
2. Open `chrome://extensions`.
3. Enable **Developer mode**, click **Load unpacked**, and choose the unzipped folder.

Developer fallback for Firefox:

1. Unzip `Firefox - AMO upload source.zip` from the DMG.
2. Open `about:debugging#/runtime/this-firefox`.
3. Click **Load Temporary Add-on** and choose `manifest.json` inside the unzipped folder.

Firefox removes temporary add-ons when it restarts, so this fallback is only for beta testing while the persistent store version is under review.

## First Run

New installs start with a blank canvas and **Welcome to my desktop**. A two-page guide explains the basics.

- `~` shows or hides Intent.
- Click an intention to run it.
- `E` enters edit mode.
- `I`, `R`, and `F` add an intention, restriction, or friction.
- `S` closes the selected editor.
- `X` or `Delete` removes the selected shape.
- `Cmd+Z` undoes the last change.
- Pinch to zoom and use two fingers to pan.
- `Cmd+Tab` switches between launched allowed apps during a session.
- `Cmd+Shift+M` ends the session.

The first session asks for macOS Accessibility permission so Intent can enforce app restrictions. This is a one-time system permission.

## Backgrounds

Open the gear in the bottom-right corner to choose dark/light appearance, select a built-in medieval drawing, upload an image, paste one, or drag and drop one. Intent preserves the same adaptive glass, blur, stars, and transparency over every background.

## Build From Source

```zsh
git clone https://github.com/logx8x-ui/intent-cli.git
cd intent-cli
./scripts/install.sh
```

Run all checks and build the release DMG:

```zsh
swift run IntentCoreSpec
npm install
npm run test:extensions
npm run extension:lint
./scripts/build-release.sh
```

Intent is a personal focus tool, not security software. See [Privacy](PRIVACY.md) for its local-only data behavior.
