# Intent tester verification — 14 September 2026

Repository: https://github.com/logx8x-ui/intent-cli

Published implementation: `5f9d72e`, release `beta-20260914073600`, display version `0.9.3-beta.1`.

## Updates

- Published the signed Sparkle appcast and immutable update archive. The bootstrap installer is available at https://github.com/logx8x-ui/intent-cli/releases/download/intent-beta-feed/Intent-Tester-Mac.zip.
- Downloaded the public archive and verified its Ed25519 signature. Deliberately altered bytes failed verification.
- Sparkle 2.10.0's official command-line driver found, downloaded, extracted, installed and relaunched the update on this Mac. Installed build changed from `202609140001` to `20260914073600`; deep code-signature verification passed and all three existing intention data files retained their hashes.
- This exercises Sparkle's actual public download and installation path. It does not verify waiting for the app's hourly timer or delaying an installation during an active intention. No session was active during installation.
- The signing key and public Supabase build configuration are configured as encrypted GitHub Actions secrets.
- **Push-triggered publication remains blocked:** the GitHub connector cannot create workflow files, and the saved git credential has `repo` scope without `workflow`. The prepared workflow is `docs/automatic-beta-release.yml`; it must be activated at `.github/workflows/beta-updates.yml` through an authorized GitHub session. No successful Actions release run has been observed yet.
- Friends using the older tester must install the new bootstrap once to receive the Sparkle updater. This beta is Apple Silicon/macOS 13+ and is not Apple notarized. Browser extension installation and Firefox temporary-extension persistence have separate constraints.
- Updated and deployed the friends download page to use the beta channel instead of the old stable-only catalog. The public HTML and JavaScript were fetched successfully and the live GitHub release resolved for all three browser choices. Cloudflare deployment: `a116469b-050f-451f-ba53-0aa4a95592e2`. Visual/browser interaction acceptance could not be repeated because Chrome control disconnected.

## Fixes and acceptance

- Permission readiness now includes Accessibility, Screen Recording, and the selected browser's tab-selection capability. The setup opens the relevant settings in sequence; Cmd+G checks permissions before opening the overview.
- Window enumeration rejects off-screen/utility/duplicate surfaces. Capture retries and a legacy fallback improve previews; an unavailable capture displays the app name and window title. The live overview on this Mac showed real Chrome/Firefox tab choices and distinct Anki windows without anonymous blank tiles.
- The app bundles Browser Guard 0.2.9 and its native host, repairs per-user host registration, and offers browser-specific setup. Regression tests cover idle-only Chrome reload and reload-loop prevention. Fresh browser installation on the friend's Mac remains a physical acceptance step; Firefox's temporary extension must be reloaded after Firefox restarts.
- Passwordless email/code UI is implemented. The original Supabase project was resumed and its public Auth settings confirm email signup is enabled and verification is required. **Actual email delivery, code/link verification and account isolation/sync remain unverified.** Custom SMTP and redirect/template settings still need inspection through the signed-in owning account.
- The new bootstrap marks fresh installation for a local reset; ordinary updates preserve data. Swift fixture tests and actual installer fixture tests cover fresh installation, update, reinstall, reset retry and system-install migration. This does not promise detection of every arbitrary drag-and-drop reinstall using an old installer.
- Core, account, purpose-matching, browser, native-host, release-readiness and installer checks passed; release build and local data-preserving installation passed. Fresh macOS permission granting and the friend's full session remain unverified.

## Research delivery

The half-page analytics and Cmd+G habit plan in `intent-analytics-habit-plan-2026-09-14.md` was sent to the authorized WhatsApp recipient, dylkai seet. The sent message and empty composer were verified.
