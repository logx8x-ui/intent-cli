# Instagram native controls — October 9

## Reproduction and scope

User authorized temporarily pausing Unscroll Instagram for live QA. Daily Firefox
profile `ykomjweq.default-release` had permanent Browser Guard 0.2.39 and enabled
Unscroll 2.5. Unscroll was disabled through its normal add-ons switch, then restored
to enabled after inspection. No user tabs or account settings were removed.

Normal Home exposed twelve Story controls as MAIN descendants with structure
UL > LI > DIV[role=button][aria-label="Story by …, not seen"], without a story href.
The floating Messages launcher was DIV[role=button] containing
SVG[aria-label="Messages"]. Existing link-only handling missed both surfaces.

A live Stories-only intention on .39 kept Home accessible, hid the observed
canonical-permalink feed posts, retained the Story controls, and successfully
opened Intent's own brand Story. An unrelated ARTICLE without post permalinks
remained visible by design. The floating Messages launcher incorrectly remained
visible with Messages disabled. Test finished via the ordinary Finish menu.

## Fix

Both guards classify the observed native Story buttons within MAIN/UL and the
floating Messages button by its Messages SVG. Each surface follows its own
feature permission, including clicks on descendant icons before the next render.
Story item markers are Home-only; recycled DOM, changed rules and Finish clear
stale markers. No whole-MAIN or arbitrary-avatar hiding was added.

The Story fallback uses the observed English accessibility label. Other locales
and unobserved Instagram redesigns are not certified; URL restrictions remain
independent. Existing link handling and YouTube behavior are unchanged.

Browser Guard and the bundled host requirement advance together to 0.2.40.

## Verification

- Both actual content scripts pass the 32-option DOM/route matrix, now including
  native Story buttons, floating Messages, nested-icon clicks, dynamic insertion,
  stale-node cleanup, unrelated labelled elements and Finish cleanup.
- The new regression fails on the original HEAD guard at native Story visibility.
- Full `npm run test:changed` passed all eight suites. Evidence:
  `intent-change-gate-SzAL4N/result.json`, fingerprint
  `26e941f03645251bc017dff2cc6018a5fe89029da407b7ad652fed117d2e51cf`.
- Development installation completed. App UUID unchanged:
  `85ECD920-A33A-3E59-9ACE-232BA2B73E3B`; matching host UUID
  `1EE65625-6C30-39F4-84E2-7D34E5B37086`.
- Fresh Chrome heartbeat reports 0.2.40. Authenticated Instagram acceptance in
  Chrome has not been exercised.
- Mozilla accepted 0.2.40 with zero validation errors/warnings, version 6556736,
  file 5100875. Signing and final Firefox acceptance remain pending.
