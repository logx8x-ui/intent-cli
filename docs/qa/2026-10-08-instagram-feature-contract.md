# Instagram feature contract — 2026-10-08

## Status and scope

**October 9 follow-up:** normal Home and the native Story / floating Messages
controls have now been observed after an authorized Unscroll pause. See
[the native-control follow-up](2026-10-09-instagram-native-controls.md) for the
fix and exact installed verification. The historical limitations below describe
the October 8 inspection, not the later result.

This documents the current source implementation and focused automated evidence in the primary Documents checkout. It is **not installed-build or live-browser acceptance** of all combinations. The normal authenticated Story tray still needs live DOM evidence; no guessed production selector has been added for it. Fresh live evidence confirms that the current native Search anchor targets `/explore/`, already covered by the route policy. Root owns the full gate, versions, installation, signing and live QA.

The five independently stored controls are Messages (`M`), Feed (`F`), Reels (`R`), Stories (`S`) and Explore & profiles (`E`). A checked control grants that area only after the outer intention permits the tab and URL. Old saved intentions without an Instagram policy keep their previous behavior. New Instagram policies default to Messages only.

## Routes and surfaces

| Native area or route | Required selection | Current implementation and boundaries |
| --- | --- | --- |
| Home `/`, including query/hash variants | F or S | Retains the native home shell for Stories-only; does not grant Feed implicitly. |
| Home post feed | F | On the exact `/` pathname, a `main article` is marked only when its own nearest-ARTICLE descendant anchor is a same-site `/p/` or `/reel/` permalink; dynamic insertion is covered. The marker is removed when Feed is enabled, the route changes, or the intention finishes. |
| Home Story tray | S | Intended to remain usable with S alone and to hide independently when S is off. `/stories/` links are suppressed when disabled; the actual tray/container selector is still pending live evidence. |
| Inbox, thread and composer under `/direct` | M | Thread shell remains usable. Turning M on does not grant a shared post/Reel's separate destination. |
| `/reel`, `/reels`, their child routes | R | Direct navigation, SPA routes and links use the same feature decision. |
| `/stories`, its child routes | S | Story viewer is allowed independently of Feed. Home feed ARTICLE hiding does not run on this route. |
| `/explore`, search/profile routes | E | Profile and Explore navigation use E. The observed native Search anchor goes to `/explore/` and is covered; no same-route Search drawer was observed in this layout. |
| `/<profile>/reels/` | E and R | Explicit profile Reels restriction closes the old E-only route escape, including encoded paths; reserved roots such as `/stories/reels/123/` are not confused with profiles. |
| `/<profile>/`, `/<profile>/tagged/` | E | Profiles and their post grid are included in Explore & profiles, even if the Home Feed is disabled. |
| `/p/<post>/` | F or E | Feed and Explore/profile users can open standalone posts. Messages-only and Stories-only cannot open this separate post viewer. |
| Login, logout, one-tap, password, edit, challenge and two-factor support routes | Any valid nonempty policy | Kept available to avoid trapping login/recovery. They do not override outer bans. |

Unknown descendant paths currently inherit E unless overridden by a known feature route. This preserves existing profile/support behavior but is not proof that every present or future Instagram route is classified. Profile-qualified singular Reels and post permalinks are open audit items below.

## All 32 combinations

Mask bit order is M, F, R, S, E, matching the independent test fixture. The entry column applies **only when the current Instagram route is disabled**. A current allowed route is left alone. Within every row each enabled Messages/Reels/Stories/Explore area remains independent; Home has Feed content only if F is on and should have Story affordances only if S is on.

| Mask | M | F | R | S | E | Entry after a disabled route |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | — | — | — | — | — | Invalid; no fallback |
| 1 | On | — | — | — | — | Inbox |
| 2 | — | On | — | — | — | Home |
| 3 | On | On | — | — | — | Home |
| 4 | — | — | On | — | — | Reels |
| 5 | On | — | On | — | — | Inbox |
| 6 | — | On | On | — | — | Home |
| 7 | On | On | On | — | — | Home |
| 8 | — | — | — | On | — | Home |
| 9 | On | — | — | On | — | Home |
| 10 | — | On | — | On | — | Home |
| 11 | On | On | — | On | — | Home |
| 12 | — | — | On | On | — | Home |
| 13 | On | — | On | On | — | Home |
| 14 | — | On | On | On | — | Home |
| 15 | On | On | On | On | — | Home |
| 16 | — | — | — | — | On | Explore |
| 17 | On | — | — | — | On | Inbox |
| 18 | — | On | — | — | On | Home |
| 19 | On | On | — | — | On | Home |
| 20 | — | — | On | — | On | Reels |
| 21 | On | — | On | — | On | Inbox |
| 22 | — | On | On | — | On | Home |
| 23 | On | On | On | — | On | Home |
| 24 | — | — | — | On | On | Home |
| 25 | On | — | — | On | On | Home |
| 26 | — | On | — | On | On | Home |
| 27 | On | On | — | On | On | Home |
| 28 | — | — | On | On | On | Home |
| 29 | On | — | On | On | On | Home |
| 30 | — | On | On | On | On | Home |
| 31 | On | On | On | On | On | Home |

The four Home-surface cases cover the full cross-product with M/R/E:

- F off, S off: Home is unavailable; use Inbox, then Reels, then Explore, in that preference order.
- F off, S on: Home remains as the Story entry; post feed is hidden.
- F on, S off: Home feed remains; Story affordances must be hidden independently.
- F on, S on: Home feed and Stories both remain.

All-off is an invalid Instagram policy, not unrestricted access. The native UI shows “Choose at least one allowed area”; normal Run and `QuickSelection.makeIntention` validate the policy. If an invalid or unknown-version policy reaches the extension, Instagram routes fail closed and no fallback navigation is generated. Removing the entire policy instead preserves the legacy behavior; this is distinct from an empty checked set.

## Landing and outer-rule priority

For a feature-disabled Instagram route, the shared engine chooses exactly one landing URL:

1. `https://www.instagram.com/` when F or S is enabled.
2. Otherwise `https://www.instagram.com/direct/inbox/` when M is enabled.
3. Otherwise `https://www.instagram.com/reels/` when R is enabled.
4. Otherwise `https://www.instagram.com/explore/` when E is enabled.
5. No destination for all-off/invalid/missing policy.

The existing background adapter changes only the current tab's URL. It does not activate, create or close a tab/window. It checks the current policy identity and selected-tab/outer-URL permissions for both source and destination. An allowed landing has no fallback and therefore does not loop.

Chrome uses the same destination for request-stage DNR redirects. Feature blocks have priority 800; eligible source-scoped redirects use 801; explicit excluded URL sources use 802. Exact selected-tab/blacklisted-tab restrictions remain at priority 1000 or above. Crucially, redirects are emitted only for sources and a destination allowed by the outer URL policy; their higher numerical priority must never be treated as permission to reopen an outer-denied URL. No new DNR `allow` rules were added. Firefox performs equivalent source/destination checks in its request and runtime adapters.

Examples covered by tests: an unselected tab stays blocked; a URL whitelist containing only `/reels` cannot route to an otherwise-disallowed Home; an Instagram blacklist cannot be reopened through a Stories fallback; a profile-scoped fallback cannot capture a different profile URL.

## Evidence and limitations of the feed selector

Root's live inspection on 2026-10-08 found three feed posts under the authenticated Firefox Home main region; each used `ARTICLE` with no role or class. The pathname was `/` with `?variant=following`. Parent wrappers were DIVs. A follow-up read confirmed that all three ARTICLEs contained canonical same-site `/p/` permalink anchors. Native Home, Reels, Search and Messages SVG controls were inside anchors pointing to `/`, `/reels/`, `/explore/` and `/direct/inbox/` respectively. Another Messages SVG had a DIV with `role=button` as its nearest control; its behavior has not been exercised.

Chrome was logged out. Firefox had active Unscroll Instagram 2.5, which forced the Following variant; normal Home and Story tray acceptance was therefore unavailable. No story-anchor or story-label match in that altered page is evidence about that page only, not evidence that Instagram has no Stories UI.

After that follow-up observation, the detector was narrowed: Home MAIN → ARTICLE → canonical same-site `/p/` or `/reel/` anchor whose nearest ARTICLE is that candidate. An arbitrary ARTICLE, a Stories-only ARTICLE, a same-shaped external `/p/` URL, or a parent ARTICLE containing a separate nested post no longer counts as a post. No obfuscated classes, text contents or guessed Story selectors are used. The marker is recalculated after insertions and is removed if the identifying link disappears.

The remaining structural limit is that a non-feed ARTICLE with its own canonical post link could still be misclassified, while a real feed post without its canonical link yet would not be hidden until that link arrives. The live sample establishes three feed-post structures, not every Instagram layout. The normal Story tray still needs inspection. Do not replace the narrowed detector with a blanket `main`, `[role=article]`, image or video hide.

## Automated evidence

The following focused commands passed against the current source on 2026-10-08:

- `node scripts/test-website-features.cjs`
- `node scripts/test-site-feature-guard.cjs`
- `node scripts/test-chrome-background.cjs`
- `node scripts/test-firefox-background.cjs`
- `git diff --check`

`test-website-features.cjs` has an independent explicit 32-mask Instagram truth table, including all-off, Home Feed/Stories, inbox/threads, standalone/profile Reels, Stories, profiles, tagged/posts, login and challenge. It checks landing/no-loop outcomes, encoded and malformed paths, raw outer source boundaries, DNR precedence and byte-identical Chrome/Firefox shared modules. The larger route parity matrix supplements those independent expectations; engine-versus-engine parity alone is not the contract.

`test-site-feature-guard.cjs` executes both actual content scripts in its DOM/event harness for all 32 combinations. It checks Home shell versus Feed visibility, captured link decisions, SPA entry, policy replacement, Finish cleanup and route-scoped ARTICLE exclusions. Dynamic canonical permalink insertion, a Stories-containing ARTICLE with a separate nested post, unrelated external links, and recycled ARTICLE cleanup are checked. This harness tests script behavior and observed structural fixtures; it is not a real browser rendering/layout test and does not establish the still-unknown Story-tray selector or the extra Messages button behavior.

The background fixtures exercise same-tab fallbacks for Stories, Reels, Explore and Messages+Stories through both the initial network request adapter and runtime content-message adapter. They assert no new/activated tabs, no landing loop, current policy identity, and retained outer restrictions. Existing readiness, cancellation and YouTube playback regressions remain passing.

The largest combined Instagram+YouTube generated set remains 437 feature rules plus 3 reserved exact-tab/search rules, below Chrome's 1000 session-regex limit. The new Explore-only profile-Reels set contains 216 rules; its longest regex is 938 characters and contains no lookaround. Actual Chrome `isRegexSupported` and installed enforcement remain root's live/release gate; string length and JavaScript matching alone are not Chrome acceptance.

## Remaining concrete audit items

1. **Story tray / extra Messages button:** no production tray selector yet. `/stories` route bans work, but native affordances that do not navigate cannot be certified by a route ban alone. The observed Search anchor is `/explore/` and covered; no same-route Search drawer was observed. An additional Messages SVG has a DIV `role=button` control rather than an anchor, and the existing anchor-only guard does not hide or intercept that control. Its actual navigation/drawer behavior needs checking. Observe normal authenticated Home after an authorized temporary Unscroll pause, then restore the user's extension state.
2. **Profile-qualified singular Reel URL:** with E on and R off, the current engine permits `/<profile>/reel/<id>/` because only the plural profile-Reels section has an explicit override. This is a demonstrated engine verdict; verify whether the native UI emits that alias before claiming a production bypass or adding an alias rule.
3. **Profile-qualified post URL:** with F on and E off, `/p/<id>/` is allowed but `/<profile>/p/<id>/` is denied by the profile fallback. If native feed permalinks use that alias, Feed-only users would be overblocked. Obtain the observed canonical link shape before changing the classifier.
4. **Posts in Explore/profile grids:** E intentionally grants posts even when F is off. R off must still prevent actual Reel navigation; a Reel displayed through a `/p/` alias cannot be inferred from the URL alone. Any embedded native Reel surface requires observed semantics, not image/video-wide hiding.
5. **Shared content in Messages:** M alone permits message threads and their embedded message cards, but opening a `/p/`, `/reel/` or profile destination requires the matching selection. This is the present contract, not a bug workaround; the UI should make it clear.
6. **Navigation heuristic:** the pre-existing guard treats an anchor with any aria-label or descendant SVG/image as navigation. Thus a non-navigation profile/avatar card can be hidden when E is off even though its containing Feed/Stories/Messages surface is allowed. This needs a verified native-navigation boundary; do not infer one from every image. The click guard can continue denying the destination while preserving recognizable content.

## UI semantics review

The existing “Allowed on this site” heading, checkbox style, shared-across-selected-tabs note and all-off warning are clear. The individual meanings are less clear: “Feed” could sound like all posts, “Explore & profiles” omits Search, and Stories' use of Home is not explained. No native UI changes were made in this subtask.

Recommended follow-up copy, once the pending surfaces work: “Home feed”; “Search, Explore & profiles”; a short Stories helper saying “Stories stay on Home; posts only appear if Home feed is on”; and a Messages helper saying “Opening shared posts or Reels needs those areas enabled.” Keep them as concise hover/help text rather than another setup screen.

## Source ownership for this pass

- Shared policy and content guard: `chrome-extension/website-features.js`, `firefox-extension/website-features.js`, and both `site-feature-guard.js` copies.
- Chrome background: only the Instagram redirect destination eligibility block in `updateNetworkRules`; other concurrent native-finder edits are outside this subtask.
- Focused tests: the four commands listed above.
- Native choices/validation were reviewed read-only in `WebsiteFeaturePolicy.swift`, `WebsiteFeatureControls.swift`, `QuickSelection.swift` and `QuickSelectionView.swift`.

No Swift build, installation, signing, browser UI mutation, version change, account change or permission change was performed by this subtask.
