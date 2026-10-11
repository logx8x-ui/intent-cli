# Launch channels and download readiness — 11 October 2026

## Result

Intent now has compiled development and launch channels in one repository. Development retains the experimental T website adder; launch excludes its UI, keyboard route, and direct controller entry. The installed personal app is development. No public launch artifact or download catalog has been enabled.

Both channels preserve the stable app/native-host identity and existing data. Only one channel may run on a Mac at a time. The download page is public at `https://livewithintent.app/download`; the development page at `/download/test` requires the owner identity. The website catalog remains empty until a signed, notarized and acceptance-tested release can be pinned.

## Automated verification

`node scripts/change-impact.cjs --all --run` passed all eight suites: gate, session, Swift, extensions, native host, release, AI, and lint. The final report is `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-Kt6nOd/result.json`, completed at 09:11:37 UTC, with source fingerprint `ed081c6725a56997a045edeea058ff2e3bade4b324fb0cb3051e52c60d9ff68a`. This is automated evidence, not physical-input acceptance.

Release checks include compiled-channel fixtures, profile discovery/queue/launch-plan fixtures, and 27 download-kit tests. The kit builder rejects unsigned, development, mismatched or stale artifacts and supports Firefox-only promotion while Chrome approval is outstanding. Catalog metadata validates trusted immutable URLs and hashes; actual artifact signature verification remains a separate mandatory promotion step.

Website per-browser availability tests passed all 11 cases, and its production build passed. Firefox-only qualified releases enable Firefox alone; Chrome and Both remain unavailable until the exact official Chrome version and all three verified kits qualify. With the current empty catalog, valid download API choices return 503 rather than falling back to another release.

## Installed app and native UI evidence

After the final source gate, `./scripts/install-dev.sh` completed successfully. The installed app is `/Users/loganmondi/Applications/Intent.app`, bundle ID `dev.loganmondi.intent`, arm64 UUID `C57E1AFE-DC7C-3CEB-B9D0-72BFADEA1115`. Its safe `--print-build-channel` query returns `development`; its development metadata is true, automatic updates are false, and strict deep code-sign verification passed. Chrome and Firefox native-host manifests point to this installed app's helper.

Installed UI checks verified:

- Browser profiles opens without the overview covering it.
- Clear disables Start with no profiles selected; Select all restores all ten discovered profiles.
- Setup targeting only the Intent QA Chrome profile opens the guide in that exact profile.
- The guide displays the matching installed Browser Guard 0.2.43 and connection instructions, rather than reinstall instructions.
- Closing setup returns to the retained overview draft.
- The development app still exposes the T website-adder entry.

The Chrome test initially exposed an internal-URL rejection: Chrome opened the right profile but discarded externally supplied `chrome://extensions`. The final implementation opens an inert, HTML-escaped local guide in development; launch uses the official HTTPS Store URL. The actual final Chrome window was titled `Intent · Chrome profile setup - Google Chrome – Intent QA` and displayed the expected guide. A running Firefox profile uses its known owner process and a copied setup address, rather than routing through an arbitrary default profile.

## Local launch candidate

The updated arm64 local candidate was built with release version 0.9.3 and build 202610110001. Its manifest records `channel: launch` and `website_adder_enabled: false`; its DMG SHA-256 is `0f08f9e2921c9a67aa98d0e3a33bc5da3246d96b620646e70ace2779c18199a7`.

This candidate is unsigned, unnotarized and arm64-only. Its Firefox extension is unsigned. It is a local packaging check and is not eligible for the public catalog. Running the download-kit builder against it correctly refused with “Download kits require a notarized Developer ID release and its Apple Team ID.” Do not infer release readiness from the candidate or source checks.

## Browser publication and blockers

The exact Firefox 0.2.43 source ZIP was submitted through the owner's existing Mozilla publisher session. Validation reported no errors or warnings. Submission 6564165 finished at `https://addons.mozilla.org/en-US/developers/addon/485649d659c2420c9778/versions/submit/6564165/finish`, showing **Version Signature Pending**. The signed XPI has not yet been retrieved, verified or installed. The permanent daily Firefox installation remains 0.2.42 and needs the signed update plus exact-profile acceptance.

The Chrome Web Store currently serves 0.2.14. The 0.2.43 upload package exists locally, but an updated Chrome submission and approval have not been completed. The automation browser denied publisher-console navigation, and the separate in-app browser requires owner Google sign-in. This is not a submitted or approved Chrome update.

This Mac has no usable Developer ID Application/Installer identities, and notarization credentials are not configured. Apple Developer enrollment is open for the owner; signing, notarization and universal release verification remain blocked on that setup. Enrollment alone does not complete certificate/notary setup.

During the final publisher handoff, native computer use reported no accessible windows. No unlock or authentication was attempted. Browser/source checks continued without operating the user's locked desktop.

## Remaining acceptance before enabling downloads

Retrieve and verify the exact signed Firefox artifact; update and test the permanent profile. Complete Apple signing/notarization, build a universal launch candidate from the frozen published source revision, and verify the actual package. Test the launch app's hidden T route and adjacent tab-selection/saved-intention flows on the installed build. Verify quiet finish restores hidden windows without bringing another window or Space forward, last-resource cleanup, and the physical double-tap/tab-outline paths. The source gate still labels those physical/foreground checks pending.

A verified Firefox-only release may be published first. Chrome and Both require the exact updated Chrome Store version and matching kits. Follow `docs/launch-channels.md` for the manual immutable-tag promotion and catalog pin. No source push or website deployment enables binary downloads automatically.
