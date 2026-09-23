#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");
const json = (relativePath) => JSON.parse(read(relativePath));

const firefoxManifest = json("firefox-extension/manifest.json");
const chromeManifest = json("chrome-extension/manifest.json");
const firefoxUpdates = json("firefox-updates.json");
const hostVersion = read("Sources/IntentNativeHost/main.swift").match(/bundledExtensionVersion: String = "([^"]+)"/)?.[1];
assert.equal(hostVersion, chromeManifest.version, "The native helper must advertise the extension version actually bundled, so idle reload can update it");
assert.equal(
  firefoxManifest.version,
  chromeManifest.version,
  "Firefox and Chrome Browser Guard releases must use the same version"
);
assert.equal(
  firefoxManifest.browser_specific_settings?.gecko?.update_url,
  "https://raw.githubusercontent.com/logx8x-ui/intent-cli/main/firefox-updates.json",
  "Firefox Browser Guard must use the stable self-update feed"
);
const firefoxUpdate = firefoxUpdates.addons?.["intent-firefox@loganmondi.dev"]?.updates?.at(-1);
// The live feed follows published artifacts, not unreleased source changes.
assert.ok(/^\d+\.\d+\.\d+$/.test(firefoxUpdate?.version || ''), "Firefox feed needs a released version");
assert.ok(firefoxUpdate.version.localeCompare(firefoxManifest.version, undefined, {numeric:true}) <= 0,
  "Firefox feed must not advertise a version newer than the source");
const feedURL = firefoxUpdate?.update_link || '';
const immutableGuardAsset = `https://github.com/logx8x-ui/intent-cli/releases/download/browser-guard-${firefoxUpdate.version}/Intent-Firefox-Extension-${firefoxUpdate.version}.xpi`;
assert.ok(feedURL === immutableGuardAsset || /^https:\/\/github\.com\/logx8x-ui\/intent-cli\/releases\/(?:latest\/download|download\/v[0-9.]+)\/Intent-Firefox-Extension\.xpi$/.test(feedURL),
  "Firefox feed must use an official signed release asset matching its version");
assert.equal(
  chromeManifest.update_url,
  "https://clients2.google.com/service/update2/crx",
  "Chrome Browser Guard must use the Chrome Web Store update service"
);
assert.ok(
  chromeManifest.key,
  "The unpacked Chrome build must keep its stable development extension ID"
);

const chromeBuilder = read("scripts/build-chrome-extension.sh");
assert.ok(
  chromeBuilder.includes("--web-store") && chromeBuilder.includes("delete manifest.key"),
  "The Chrome Web Store package must omit the development-only manifest key"
);

for (const browser of ["firefox", "chrome"]) {
  const background = read(`${browser}-extension/background.js`);
  assert.match(
    background,
    /single-startup-launch-v1/,
    `${browser} Browser Guard must advertise single-launch startup safety`
  );
  assert.match(
    background,
    /getManifest\(\)\.version/,
    `${browser} Browser Guard must report its manifest version`
  );
}

const releaseBuilder = read("scripts/build-release.sh");
assert.ok(
  releaseBuilder.includes("scripts/sign-firefox-extension.sh"),
  "Public release builds must use Mozilla signing"
);
assert.ok(
  releaseBuilder.includes("firefox_extension_signed"),
  "Release manifests must describe Firefox signing"
);

const releaseVerifier = read("scripts/verify-release.sh");
assert.ok(
  releaseVerifier.includes("META-INF/mozilla.rsa"),
  "Release verification must check the Mozilla signature"
);

const quickSelectionUI = read("Sources/IntentApp/QuickSelectionView.swift");
assert.ok(!quickSelectionUI.includes("Couldn't confirm the current tab."), "Quick marks must not resurrect the blocking tab-confirmation alert");
const markRecovery = quickSelectionUI.slice(quickSelectionUI.indexOf("private func showMarkRecovery"), quickSelectionUI.indexOf("func clearMarks"));
assert.ok(!/runModal|errorMessage|showOverlay/.test(markRecovery), "Quick-mark recovery must remain nonmodal and leave the dashboard alone");

const desktopApp = read("Sources/IntentApp/IntentDesktopApp.swift");
assert.ok(
  desktopApp.includes("IntentMenuBarIcon.makeImage()"),
  "Intent must use its monochrome menu bar mark instead of the full application icon"
);
assert.ok(
  desktopApp.includes('NSMenuItem(title: "Close Intent"'),
  "The menu bar context menu must let the user close Intent"
);
assert.ok(
  desktopApp.includes(".terminationOnRemoval"),
  "Removing Intent's menu item must close the app instead of leaving a hidden process"
);
assert.ok(
  desktopApp.includes('"NSStatusItem Preferred Position \\(Self.statusItemAutosaveName)"') &&
    desktopApp.includes('"NSStatusItem Visible \\(Self.statusItemAutosaveName)"') &&
    desktopApp.indexOf("NSStatusItem Preferred Position") <
      desktopApp.indexOf("NSStatusBar.system.statusItem"),
  "Intent must repair its visible menu-bar placement before AppKit creates the status item"
);

const hotKeyManager = read("Sources/IntentApp/GlobalHotKeyManager.swift");
assert.ok(
  !desktopApp.includes('.keyboardShortcut("`", modifiers: [])'),
  "Quick Focus must not double-register its global bare-grave shortcut in the app menu"
);
assert.ok(
  hotKeyManager.includes("registerRequiredShortcut()") &&
    hotKeyManager.includes("register(.defaultShortcut, id: 1") &&
    hotKeyManager.includes("OverlayShortcut.quickSelectionShortcut.keyCode") &&
    hotKeyManager.includes("OverlayShortcut.quickSelectionShortcut.modifiers"),
  "Command-G must open Intent and bare grave must open Quick Focus globally"
);
assert.ok(
  hotKeyManager.includes("shortcut == .legacyDefaultShortcut") &&
    hotKeyManager.includes("save(.defaultShortcut)"),
  "The former Shift-grave default must migrate to Command-G"
);

const developmentInstaller = read("scripts/install-dev.sh");
assert.ok(
  developmentInstaller.includes('open "$APP_BUNDLE"') &&
    developmentInstaller.includes("Intent is running in the menu bar."),
  "The development installer must relaunch Intent and verify its menu process"
);
assert.ok(developmentInstaller.includes('Contents/Helpers/IntentNativeHost') && developmentInstaller.includes('Contents/Resources/BrowserGuard/Chrome') && developmentInstaller.includes('Contents/Resources/BrowserGuard/Firefox'),
  "Development installation must update the helper and matching extension sources together");
for (const installer of [developmentInstaller, releaseBuilder]) {
  assert.ok(
    installer.includes("chrome-extension://aibdbhjdckeeejpggfpfaghmomopjbpb/") &&
      installer.includes("chrome-extension://ffgfjfpkddgimambgmahlodjjojmjnbc/"),
    "Chrome native messaging must allow both development and Web Store extension IDs"
  );
}

console.log(`Release readiness spec passed (Browser Guard ${firefoxManifest.version})`);
