# First-intention onboarding

Replaces the AI-generated collection of starter intentions with one local, resumable flow:

1. A 540 × 340 point native window asks “What do you want to do on your computer right now?” The trimmed answer becomes the saved name.
2. A 620 × 610 point chooser shows running apps and locally evidenced frequent apps, installed-app search, browser-shared tab titles/sites and manual website entry. Choices are explicit; websites retain browser ownership.
3. Setup follows selection. Accessibility is required for focus enforcement; Browser Guard is required only for selected browsers. Screen Recording is optional for previews/blur. Status polls automatically. The setup window is 430 points tall without browser setup and grows only for selected browsers. The app icon provides a file-URL drag item for the Accessibility list; macOS still requires user approval of its switch.
4. The intention is saved once and starts through the existing session engine, without timer locks, friction, or Zero Drift. The small running card exposes Finish and the configured finish shortcut. The final page points to the saved intention and Cmd+G.

Closing or choosing Later preserves the draft and does not mark first-run onboarding complete. Returning after a failed start updates the same saved intention rather than duplicating it. A runtime failure returns to setup rather than presenting success. Existing saved intentions and onboarding completion preferences are not reset by installation.

Browser setup limitation: Chrome's Store listing is not published in the current repository distribution instructions, so Chrome setup opens those instructions in Chrome. Firefox opens the official signed XPI in Firefox. Browsers without shared tabs support manual site selection before connection. The screen does not claim that it can silently grant OS permissions or install an extension.

Validation: IntentCoreSpec passed, including name fidelity, exact app selection, browser/site validation, and draft persistence across a restart. IntentApp debug build passed. Production installation and UI observations are recorded in the task; they are distinct from a fresh-Mac permission-grant test.

References consulted: [HeyClicky's official changelog](https://www.heyclicky.com/changelog) and [Apple's Accessibility permission instructions](https://support.apple.com/en-au/guide/mac-help/mh43185/mac). The small-window and first-run direction comes from Logan's brief, not a claim that HeyClicky's exact onboarding was replayed.

## Installed UI verification

Observed the exact first question in its native 540-point window; entered Review onboarding, selected TextEdit, and reached setup with the existing Accessibility and Screen Recording grants recognised. Start launched the intention; Finish ended it, and its name appeared on the Intent desktop. Draft step 4 survived reinstall and the completion screen resumed. The temporary intention was removed by undoing its creation, Done cleared the test draft, and the blank first-question window was reopened for Logan. Final polish raises onboarding above the floating desktop and reduces permission-page empty space. Fresh-Mac OS approval and new Browser Guard installation were not exercised.
