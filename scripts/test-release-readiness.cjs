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
assert.equal(
  firefoxUpdate?.version,
  firefoxManifest.version,
  "The Firefox update feed must publish the current extension version"
);
assert.match(
  firefoxUpdate?.update_link || "",
  /^https:\/\/github\.com\/logx8x-ui\/intent-cli\/releases\/latest\/download\/Intent-Firefox-Extension\.xpi$/,
  "The Firefox update feed must point to the stable signed release asset"
);
assert.equal(
  chromeManifest.update_url,
  "https://clients2.google.com/service/update2/crx",
  "Chrome Browser Guard must use the Chrome Web Store update service"
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
  hotKeyManager.includes("registerRequiredShortcut()") &&
    hotKeyManager.includes("register(.defaultShortcut, id: 1"),
  "Shift+grave must remain registered even when a custom shortcut is configured"
);

const developmentInstaller = read("scripts/install-dev.sh");
assert.ok(
  developmentInstaller.includes('open "$APP_BUNDLE"') &&
    developmentInstaller.includes("Intent is running in the menu bar."),
  "The development installer must relaunch Intent and verify its menu process"
);

console.log(`Release readiness spec passed (Browser Guard ${firefoxManifest.version})`);
