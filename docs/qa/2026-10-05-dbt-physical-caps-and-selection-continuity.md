# DBT Caps compatibility and selection continuity — October 5, 2026

## User acceptance brief

Numbered modification toggles passed Logan's physical test of `7906cb9`, but
backtick then Caps Lock still did not Run. Preserve the exact foreground window
when finishing; restore staged modifications after overview/Escape cycles; keep
the selected-window outline while editing a modifier; highlight the browser
window owning a partial tab selection; make tab icons consistent.

## Causes and changes

- The Caps normalizer required optional stateless HID bits and discarded the
  documented Caps-specific `flagsChanged` latch-transition event. The previous
  fixture incorrectly expected that format to be ignored. A new regression
  failed before the decoder change and passes afterward. Both the global path
  and the overview's local fallback use the same decoder, including flags events.
  Sticky Caps does not imply a physically held key; duplicates, known releases
  and unrelated modifier events cannot Run. Caps-first remains dependent on
  actual physical-held evidence, not a guess from the latch.
- A bounded `quick-run-diagnostics.json` records semantic routing phases and
  aggregate counters for relevant Caps attempts. It contains no typed text,
  keycodes/flags, application identity or browser content. Writes run on a
  utility queue outside the event tap; there is no idle polling. Tap delivery
  is not model/start acceptance, and absence of this file does not prove no
  physical key was pressed (the local fallback is not separately logged).
- Overview cancellation retained the draft but restored only its outlines, not
  its staged modifier strip. The exit owner now requests both. Clear removes
  targets before cancellation so it cannot briefly recreate the cleared strip.
  Model checks inject the presentation boundary: they prove retained-draft
  dispatch, not visible panels.
- The outline worker lost its external target when Intent's modifier editor
  became foreground. Only an open staged editor opts into using the currently
  visible top external window. Closing the editor revokes that exception;
  unrelated foreground apps and hidden/destroyed targets are not borrowed.
- Overview browser highlights required every tab selected. They now mark an
  exactly identified window containing any selected tab. Browser-session and
  ambiguous-window identity checks remain fail-closed; highlighting is not a
  whole-browser allowance.
- Every icon task cleared its image and independently fetched again. Icons now
  share bounded memory-only caches and in-flight requests, retain known good
  same-site icons when a snapshot omits/fails a source, validate responses, and
  support percent-encoded image data. Session/site identity and late-response
  fences prevent unrelated icon reuse. Only browser-provided addresses are
  loaded—no third-party favicon-discovery service or cookie sharing.

## Finish-window boundary

The remaining jump is native restoration of a different minimized window,
including windows of the same Firefox process. See
`2026-10-05-exact-finish-window-followup.md`. Exact-window diagnostics and the
verifier are stricter, but automatic restoration has not been changed. A quiet
finish that leaves other windows minimized requires the requested product
choice. Its candidate is not shipped by this change.

## Verification

- Pre-SVG source-stable `npm run test:session-ui` passed: native event/routing,
  expiry and diagnostic fixtures, isolated CoreSpec, release build, 132 app-model
  assertions and 165 presentation assertions. Logs: `intent-session-checks-xBlJKm9k`;
  fingerprint `e7c45b53813f7c3338a5cf0a46a20d8603b55e819d2d8f7be29a2da8edad1a06`.
- The first gate also passed. Its icon implementation produced new non-Sendable
  `NSImage` warnings; shared tasks were changed to pass `Data` only, decoding
  and caching on MainActor. The subsequent full gates were rerun and those warnings
  are absent. The existing Command Line Tools XCTest-path warning is unrelated
  and did not prevent either build or the actual checks.
- Firefox/Chrome extension suites and native-host suites passed. Peak native-host
  test RSS was 10.4 MiB. No extension version/protocol/store change was needed.
- Native input fixtures never post desktop keyboard events and do not substitute
  for Logan's physical keyboard acceptance.

## Installed checks and the additional live finding

- The first installed follow-up matched gated UUID
  `E3A1D51F-961D-3344-9B29-4F2CDA6908D1`; strict deep signing verification passed.
  Accessibility was trusted and the gesture tap reported ready (no Carbon fallback).
- Selected a native window, enabled Timer without editing its 25-minute value,
  closed overview and observed the staged strip with Timer still on. Reopened
  through File > Quick Focus and repeated the exit cycle. The selection and
  modifier survived, and the actual strip was present after every exit.
- Selected one Firefox tab while Select all remained off. Both the accessibility
  selected state and a real screenshot showed its exact Firefox window preview
  outlined; the other Firefox preview remained unselected. No browser navigation,
  tab closing or restrictive session was performed.
- The live screenshot also exposed a missed SVG case: Gemini/Gmail icons showed,
  but the ChatGPT favicon was blank. Its SVG used `fill="none"` plus root CSS;
  AppKit accepted it while ignoring the root CSS paint. The follow-up decoder
  normalizes supported scalar root paint for the dark picker and rejects
  fully transparent output. Unsupported images retain a visible fallback.
  This prompted another full gate and development installation below.
- Physical held-key input remains unverified. An app-targeted synthetic plain
  backtick did not switch surfaces. The supported File menu path exercised the
  installed controller lifecycle, not the exact physical DBT timing sequence.
- Staged-outline visual acceptance is also limited by CUA's own foreground
  utility windows: passive sampling found they covered the selected native
  window. The outline owner correctly did not draw across an unselected covering
  window. Its editor-preservation policy has deterministic coverage, but this
  is **not** a real-keyboard/no-tool-overlay pass for the reported flicker.
- Cleared every temporary target and modifier afterward. Passive sampling
  confirmed no Intent panels remained and browser restrictions were inactive;
  the daily app stayed running. No saved intentions or browser tabs were changed.

## SVG-inclusive build and live recheck

- `npm run test:session-ui` passed with stable source throughout:
  `intent-session-checks-1jFOVADO`, fingerprint
  `42b8c8afed54dbf819dffac712eaacc1ff8d6d60b00abf5a15a7eb14e9db4279`.
  Native input, isolated core, release build, 136 app-model assertions and
  165 presentation assertions passed. The added checks cover root-CSS SVG
  paint, transparent SVG/PNG fallback and rejection of DTD/entity input.
- Development-installed and relaunched `/Users/loganmondi/Applications/Intent.app`.
  Installed executable UUID `24C8525C-6FE2-3F84-8D07-C081B059CF0B` matches
  the gated package. Bundle identity is `dev.loganmondi.intent`; strict deep
  signing verification passed. PID 43543 reported Accessibility trusted,
  gesture tap ready and no Carbon fallback.
- Reopened the real Firefox tab picker. Both previously blank ChatGPT site
  icons visibly rendered their white knot; Gemini, Gmail and DDPS icons also
  remained visible. New Tab had the intended globe fallback. No tab selection,
  navigation, session start or saved-intention change was needed for this recheck.
- Closed the overview and verified passively that Intent had no on-screen
  panels and browser restrictions were inactive. The menu-bar process remained
  running. The final diagnostic observation did not reactivate Intent.
- Physical backtick/Caps acceptance and no-tool-overlay staged editor outline
  acceptance remain unverified; deterministic coverage is not a substitute.
  Exact-window finish restoration remains unresolved pending the product choice
  described above. The Firefox installer also still reports an outdated
  permanent 0.2.28 add-on beneath the current temporary 0.2.34 connection;
  this app-only change is not a permanent Browser Guard release acceptance.

## Final review hardening and installed result

- Independent review found that UTF-16/32 XML could bypass UTF-8-only DTD/entity
  rejection. Unicode SVG text now normalizes before those checks and strips any
  obsolete encoding declaration. The AppKit vector fallback accepts only parsed,
  normalized UTF-8 SVG, not arbitrary input. Added 17 checks covering LE/BE,
  BOM/no-BOM, visible icons and forbidden declarations.
- Reran the complete stable-source gate: `intent-session-checks-rTruzM5M`,
  fingerprint `365a1af83ca98373ca8ad9b302ce59d708854a2d35fdfb5d3817962fecad44be`.
  All steps passed, including 153 app-model and 165 presentation assertions.
- Reinstalled the reviewed build. Final installed/gated UUID:
  `0A7DDFAE-5A2F-34D4-8AB2-F73C9148D622`; strict deep signing passed, PID 50558,
  Accessibility trusted, gesture tap ready, no Carbon fallback.
- Repeated the real Firefox picker screenshot after this installation: both
  ChatGPT icons and the other previously visible favicons still rendered.
  Closed the clean draft; passive sampling confirmed no Intent panels and
  inactive browser rules while the menu-bar process remained alive.
- The physical-input, staged-outline visual and exact-finish limitations above
  remain explicit; this extra icon verification does not resolve them.
