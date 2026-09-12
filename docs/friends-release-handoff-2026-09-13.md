# Intent friends-release handoff — 13 September 2026

## Implemented

- First-intention picker resolves the real desktop image through ImageIO and falls back to a ScreenCaptureKit snapshot of desktop layers for dynamic/video wallpapers. It excludes ordinary app windows, Finder icons, notifications and widgets. The previous 24-point blur and 65% black veil are removed; a 22% tint and material cards keep controls readable. It uses the panel's display. Desktop capture never prompts for permission during app selection; a translucent material is the fallback when neither a wallpaper file nor an existing capture grant is available.
- Google sign-in checks that the configured account service is reachable and the Google provider is enabled before opening a browser. An unavailable service leaves the guest workspace intact and offers a clear retry/guest message.
- Update checks now run at launch, every six hours, and on activation after six hours. The existing update banner and signed-installer verification remain; installation is user-initiated, not a surprise restart.
- `docs/release-automation.yml` builds on semantic version tags, runs checks, provisions a temporary signing keychain, builds a universal macOS installer, notarizes/verifies it, makes the browser kits, and publishes the complete release. It advances the existing Firefox feed only after downloading and verifying the actual published XPI. Once signing, account recovery, and physical acceptance are complete, set repository variable INTENT_AUTO_RELEASE=true to release tested main-branch pushes automatically. Until enabled, main pushes do not publish. Version tags are also supported. INTENT_RELEASE_SERIES defaults to 0.9 and the workflow run number is the patch version; the pipeline refuses a version older than or equal to the current release.
- `scripts/build-download-kits.py` produces one ZIP for each available browser choice. Every kit includes the installer and a short setup page; Firefox kits include the signed XPI. Chrome kits require `INTENT_CHROME_WEB_STORE_URL`, so they use the store's install/update flow. The workflow does not submit Chrome Store updates; those must be published through the Chrome developer account.
- Unlisted download site source: `/Users/loganmondi/Documents/Codex/intent-friends-download`. It excludes itself from indexing, requires no visitor login, and discovers the latest published kits. No private user data or app credentials are included.

## Verified / blocked

Account/core specs, download-kit selection/checksum gates, website release-selection checks, and release-readiness checks passed. Development build installed; source/installed UUID and app signature checked. The Mac locked before native visual acceptance, so the new wallpaper fallback and friendly sign-in error have not been visually accepted.

The installed Supabase project is `cwfbvvrmnnfhzpkhbckc`. Its hostname currently returns NXDOMAIN (independently checked through Google DNS). The connected Supabase account exposes a different project, not Intent; the dashboard requires GitHub sign-in. This is a service/access blocker, not a successful Google login. Do not point Intent at the unrelated project or recreate accounts without identifying the original project and preserving its data. Restore access, unpause/restore the original project if available, then run `python3 scripts/check-account-service.py` and complete real Google consent/callback and clean-account isolation checks.

The currently published GitHub release is v0.8.1. It lacks the signed release manifest used by the current updater and has no new browser kits. Do not label that download as the new onboarding build. The website must remain in its preparation state until a verified release exists.

No Developer ID signing identities are installed on this Mac. The signing and release workflow is prepared but cannot execute successfully until enrollment and secrets are configured. No unsigned development build was published.

## Logan's next actions

1. Enroll at https://developer.apple.com/programs/enroll/ as an Individual unless using an existing legal company. Use your legal name and Apple Account with two-factor authentication. Apple lists USD 99 per membership year, with regional pricing. This gives access to Developer ID signing and notarization for direct downloads; an App Store listing is not required for this distribution route.
2. Sign into the Supabase dashboard with the account that owns Intent. Recover the original project rather than using the unrelated connected project. The live browser handoff is on GitHub sign-in for Supabase.
3. Unlock the Mac for the wallpaper and actual Google callback acceptance run. Finish the Chrome Web Store developer setup/publishing so Chrome users can install and automatically update without Developer Mode.

After Apple enrollment: create Developer ID Application and Developer ID Installer certificates, install their private keys, and configure notarization. Keep all secrets out of chat/source; use Keychain locally and GitHub Actions Secrets for CI.

Required CI secrets are listed explicitly in `docs/release-automation.yml`: signing identities, exported signing certificates and password, temporary keychain password, Apple team/notarization credentials, Supabase public build configuration, the existing Calendar OAuth credential, and Mozilla signing credentials. `INTENT_CHROME_WEB_STORE_URL` is a nonsecret repository variable. Configure them through the provider's secure settings. After a final physical acceptance run, enable INTENT_AUTO_RELEASE for main pushes, or push a new version tag. The workflow then publishes; the page finds the kits and existing current-version apps find the update. Older v0.8.1 clients still need an actual upgrade-path test before promising automatic migration.

Sources: https://developer.apple.com/programs/enroll/ ; https://developer.apple.com/developer-id/ ; https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions ; https://extensionworkshop.com/documentation/manage/updating-your-extension/ ; https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications

Website published successfully through the existing Cloudflare account after Sites source pushes repeatedly failed at the server (protocol error). Live URL: https://intent-friends-k8m4.logx8x.workers.dev . An unauthenticated HTTP check returned 200 and `X-Robots-Tag: noindex, nofollow, noarchive`. The download remains gated until signed kits are published. Canonical website source is now tracked in `website/download/`; deploy its wrangler.jsonc using the existing Wrangler installation. No owner-private content was published. Browser rendering QA was unavailable after the Mac locked.

Build tool repair: the Homebrew Node installation had a missing simdjson dylib; reinstalled Node and its required dependencies. The active `node` command resolves to the working Node 24 installation. This did not resolve the Sites source-host protocol error, so publishing used Cloudflare.

GitHub rejected publishing the workflow using the local Git credential because it lacks workflow permission. The exact workflow is preserved as `docs/release-automation.yml`; activate it at `.github/workflows/release.yml` with an authorized GitHub session, then configure the release secrets and switch. App/source changes can still be pushed with the existing credential.
