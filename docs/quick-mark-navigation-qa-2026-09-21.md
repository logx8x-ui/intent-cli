# Quick-mark handoff, navigation and tab contours — 21 September 2026

## Scope

- Wait for queued foreground marks before presenting the overview; keep the same staged selection.
- Match a changing foreground title only when fresh browser focus and exact native geometry agree. Background/profile mismatches remain unselected.
- Replace the misleading “tab is still changing” notice with an explanation and visible tab-picker/setup actions.
- Use a thinner inset contour, including a shaped Chrome horizontal tab border.
- Gate Cmd+T and native browser address controls on Searches. Treat browser-reported typed/generated/bookmark address transitions separately from page links; retain ordinary channel/link navigation.
- Authorize new search tabs with the current intention session ID, never with an unrestricted discovery snapshot.
- Fix Chrome content-script startup: callback-style runtime.sendMessage does not return a Promise. The previous .catch call threw before registering click handlers; this was observed in the real QA profile.

- Add TextEdit and QuickTime Player to first-install always-allowed defaults. Migrate the prior default pair once; retain customized/empty lists and subsequent removals.

## Verification so far

- Chrome and Firefox background tests pass, including direct address restoration, search enabled/disabled, normal links, and keeping unselected tabs intact.
- Chrome and Firefox rules tests and inactive-work tests pass.
- Firefox self-hosted validator: zero errors, warnings or notices.
- Final all-product release build passed (452.31 seconds). IntentCoreSpec passed, including default migration/custom-list/removal cases and address-control distinction. Native host and snapshot freshness tests passed for both browsers.
- Chrome QA profile loaded 0.2.13 and its native heartbeat reports quick-selection, group and session-identity capabilities.

## Installed QA check

Packaged and signature-verified `package-NDfK0F0g/Intent QA.app`, preserving the existing isolated `intent-qa-dW8GexAs` data root. Launched it and verified the saved always-allowed list migrated from Finder/System Settings to all four requested apps, with the v3 marker present and browser rules inactive. macOS requested a screen-recording permission refresh. The Mac locked during the subsequent reopen, preventing the final visual overview/outline and physical shortcut checks. A different QA artifact was running after the system reopen; explicitly select the intended artifact on resume rather than assuming Launch Services picked it.

## Distribution facts

The public Firefox update feed still advertises 0.2.5. Source versions are now 0.2.13; this is not a signed release or an updated public feed. The configured Chrome store item could not be independently retrieved through web lookup. Existing native setup still offers unpacked Chrome and temporary Firefox installation; that workflow does not meet the hands-off consumer-install goal.

Browser-profile installation is distinct from signing into another website account. Each separately used browser profile needs a guard. A heartbeat from a different profile is not proof that the foreground profile is connected.

## Limits

A committed-navigation fallback restores a disallowed typed URL after navigation begins; it is not proof that no network request occurred. Native input prevention needs physical/live acceptance. Custom browser themes, Firefox sidebars, tab groups and Mission Control animation require visual validation; a finite test suite does not certify every browser layout. No daily app replacement, account changes, GitHub push, store publication or signed extension release is included in this isolated QA pass.

## Live continuation: defaults and overview verified

On September 21, the exact package-NDfK0F0g QA build opened the overview after resetting only dev.loganmondi.intent.qa ScreenCapture and Accessibility records and re-adding that exact app through System Settings. Merely adding or toggling the old entry did not resolve stale ad-hoc build permissions. Daily Intent permissions were untouched.

The live overview exposed Finder, System Settings, TextEdit and QuickTime Player together in Always allowed, with none in the main window grid. Settings exposed individual removal buttons for all four. Calculator selected and deselected correctly; Run enabled and disabled accordingly. Escape closed the overview. Saved defaults contained all four and browser rules were inactive afterward. This confirms preset presentation and app selection, not live browser enforcement or physical shortcut acceptance; those remain unverified on this build.
