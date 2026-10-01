# Silent session finish — October 1, 2026

Removed the generic full-size running-session utility screen (name, Finish intention, Hide controls). Sessions without Timer, Checklist or Stopwatch no longer open that fallback when controls are toggled. The compact modification controls remain available.

All normal completion paths share immediate dismissal of utility, modification and expiry panels. Timer expiry no longer requests its completion toast. Stale non-session error state no longer reopens the utility panel on successful completion. Actual failure/safety reporting remains intact.

Immediate dismissal overrides a running opening animation, and presentation generations prevent stale animation completions from refocusing or hiding newer presentations.

Validation:
- Release IntentApp build passed.
- Isolated app/model suite passed: 33 assertions, including a presenter probe asserting immediate dismissal of all three panel types without show/activation requests.
- Development installation and strict/deep signature verification passed. Source and installed executable UUID: FA136BB6-4710-3978-9558-DE3E69786042.
- Live temporary Calculator blacklist session started with no modifications. No generic running-session panel appeared. Opened Settings deliberately, then used File > Finish Intention. Afterwards CUA reported no Intent windows, and browser rules were inactive.
- No browser extension changes. No user tabs, documents or saved intentions removed.

Limits: the physical finish shortcut, timer expiry and checklist completion were not separately replayed live in this pass. They use the shared completion cleanup; foreground-window preservation was not independently measured by this menu-driven test.
