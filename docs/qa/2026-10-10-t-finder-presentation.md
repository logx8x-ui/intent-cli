# T finder presentation repair — October 10, 2026

## Report and cause

Logan reported that T showed an Add from Firefox bar over the overview rather than the compact real browser. The finder companion hosted SwiftUI without disabling automatic window-size negotiation. Separately, the T path relied on WebExtension windows.create(focused:) to activate the browser process. The adjacent native tab-picker resolution already documents that Firefox can focus an internal window without activating its macOS app.

## Scoped fix

The companion uses an explicitly framed NSHostingController with sizingOptions disabled and bounded status text. Successful authenticated open now hands off activation once to the PID of the selected existing native browser window. The callback checks the current finder target/generation, closing state, process bundle and current foreground app. Cancellation before open prevents activation. No browser is launched merely to perform the handoff, and there are no delayed activation retries.

## Verification

- Five serial change-impact suites passed: gate, session, swift, extensions, host.
- Evidence: /var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-r9g5zV
- Fingerprint: fb8b3d8088826adad743ec8442c6e26f6b8c2a6496d23659f756df178c4154c5
- The first gate was invalidated by subsequent source edits; it is not final evidence.
- Release app built and development installation completed; installed UUID 8845815B-D3B5-35CD-9647-E27A73C18E19 at /Users/loganmondi/Applications/Intent.app.
- Regression exercises production hosted controls through initial layout and asynchronous status/button updates; verifies exact-once browser-open callback and no callback after early cancellation.
- Live T key sent through native automation from Firefox tab picker: browser address bar focused without an additional activation click. Independent read-only native query confirmed Firefox PID 630 foreground; finder 760x560 at (475,246), companion 580x76 at (565,820).
- Finder screenshot: /tmp/intent-t-finder-fixed.png. It shows the real Firefox profile with its existing bookmarks/sidebar in the compact browser.
- Navigating to https://example.org/?intent-qa=t-fixed-oct10 automatically returned to Intent, removed the finder/companion and selected the exact created tab. Run opened that exact URL successfully without reselection/error.
- Native automation transport interrupted while submitting Return; it reconnected. Navigation was then submitted using the actual address-bar Go button. This is not a clean physical Return acceptance test.
- Temporary focus session was ended by normal app Quit (Cocoa command delivered through the existing Intent handle), and Intent relaunched. Journal confirms the QA record has endedAt. Synthetic global finish/safety shortcuts did not exercise registered global delivery. They are not counted as physical passes.
- The installer still reports permanent daily Firefox Guard 0.2.42 versus embedded 0.2.43; this pre-existing setup gap is unchanged. Live finder advertises automatic selection support and passed this scoped flow, not complete matching-component acceptance.

## Limits

Chrome native finder, physical hardware shortcuts, delayed exact-window completion traces, other display/Space arrangements and Cancel after this final installation were not live re-exercised. Cancellation and superseded-result lifetime checks passed in isolation. This repair is not a claim that unrelated restoration or tester-readiness gaps are resolved.

## Chrome follow-up — October 11

- Verified unchanged primary source `22e9e63` and installed executable UUID
  `8845815B-D3B5-35CD-9647-E27A73C18E19` before attempting native UI QA.
- Re-ran the Chrome rule helpers, Chrome background behavior, native finder
  extension suite and native finder host protocol suite; all passed. These
  are deterministic logic checks, not a live add/Run acceptance result.
- The last persisted Chrome guard heartbeat reports 0.2.43, but was about
  30 minutes old when checked. That version alone does not prove the newly
  opened Intent QA profile has a live matching guard connection.
- Supported native UI opened the existing Intent QA profile from Chrome's
  profile picker. Before opening Intent through Finder, the foreground changed
  and the automation rejected the next input. No text was entered into the
  changed destination. Requested a brief hands-off testing window and stopped
  desktop actions pending the user's response.
- The final installed Chrome compact T/add/cancel/Run matrix remains NOT
  EXERCISED. No focus session was started during this follow-up, and no user
  tabs were closed. A blank tab in the existing QA profile was opened.
