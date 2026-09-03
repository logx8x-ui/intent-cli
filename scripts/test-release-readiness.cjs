#!/usr/bin/env node

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (relativePath) => fs.readFileSync(path.join(root, relativePath), "utf8");
const json = (relativePath) => JSON.parse(read(relativePath));

const firefoxManifest = json("firefox-extension/manifest.json");
const chromeManifest = json("chrome-extension/manifest.json");
assert.equal(
  firefoxManifest.version,
  chromeManifest.version,
  "Firefox and Chrome Browser Guard releases must use the same version"
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

console.log(`Release readiness spec passed (Browser Guard ${firefoxManifest.version})`);
