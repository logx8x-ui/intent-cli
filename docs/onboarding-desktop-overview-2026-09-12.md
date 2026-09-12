# First-intention desktop overview

The first answer becomes the session name. The compact question panel expands into a desktop-sized app overview with a blurred wallpaper, large landscape app cards, green selection outlines, and a centered transparent search field above a thin rule. The transition respects Reduce Motion. Open apps and frequent apps have separate horizontal rows; search covers the installed catalog.

Chrome and Firefox have separate expandable website lists. Shared Browser Guard tabs retain their browser ownership and titles. Manual websites can be added within each browser, and selecting a website includes its browser. Browser sessions still require at least one website and an active Browser Guard connection.

The question and overview teach Cmd+G and the configured finish shortcut. Arriving at setup automatically opens Accessibility settings if access is missing, once per guide presentation. macOS still requires the user to grant access. Screen Recording remains optional, and its setup button opens its settings page. No screenshot permission is needed to display the app cards.

The first intention runs temporarily, without adding a saved intention to the desktop. Successful completion uses the normal Save/Forget session sheet with the exact name, apps and websites selected. A failed start leaves the draft available for retry. Existing saved intentions and browser enforcement are unchanged.

Validation:
- `swift run IntentCoreSpec` passed; debug app build and release installer passed.
- Installed native UI visually checked: desktop-sized rows, underlined search, selection styling and compact setup panel.
- Firefox manual website selection and Chrome shared-tab selection correctly selected their respective browsers. Removing those browsers cleared their selected sites. App search found TextEdit.
- A TextEdit-only first session ran and ended; the normal Save/Forget sheet appeared with the exact name and resource count. No saved JSON contained the test name while running. Forget discarded the QA result.
- This Mac already has Accessibility and Screen Recording access. Fresh-Mac permission grant and the drag-to-settings gesture remain unverified; existing grants were preserved.
- Transition timing and Reduce Motion are implemented; screenshots confirm the resulting layout, not frame-by-frame animation smoothness.
- Final polish filters background system helpers out of recommendations (still searchable), opens the browser dropdown when its card is selected, and registers the Accessibility request before automatically opening Settings.

Final installed build rechecked: helper suggestions removed, Chrome card automatically expands Chrome websites, and the first question was left blank for Logan. App signature verification passed; installed and release Mach-O UUIDs match (`6681437E-3E64-343F-B31C-366BB26FE564`). The development installer also updated both browser native-host manifests.
