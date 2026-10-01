# Spread overview and browser input — October 1, 2026

## Changes

- Removed the automatic expanded app sheet, including its Done/Escape panel and four-window preview limit.
- Every window has a direct overview preview. Multiwindow groups use a shared preview scale, staggered partial overlap and larger allocated footprints; hovering changes only front-to-back order.
- Window captions have their own bounded, clear rectangles below previews. Long titles truncate at the end, have no backdrop, and cannot collide with neighbouring previews. Recent intentions remain a layout obstacle.
- Hidden-tab sessions leave tab/sidebar row clicks to Browser Guard. Native masks are restricted to the actual receiving window; a changed active title cannot inherit a stale full-window mask. Tab searches permits a fresh tab/window shortcut even from a blocked browser window.
- Both extensions now permit direct typed/search navigation under Add as you go and ordinary blacklist policy while retaining explicit bans.
- Background page loads and background-created search tabs no longer replace the user's recovery tab.
- Stopping enforcement precedes tab restoration. Rule applications are serialized and revision-guarded so a delayed old restore cannot overwrite a newer intention.
- Browser Guard source and bundled native-host version advanced to 0.2.25.

## Verification completed

- IntentCoreSpec, PurposeMatcherSpec and IntentAccountSpec passed.
- Layout assertions cover all window IDs, equal scale, caption/preview collisions, staggered exposure, nine-window groups and stable geometry on tab-count changes; existing field-of-view coverage includes 1–50 windows.
- Repeated shortcut sequences (100), native input policy regressions, and app persistence suite (33 assertions) passed.
- Firefox/Chrome rules and background suites passed, including reproductions of all three browser defects above before their fixes.
- Browser idle work, popup, tab visibility/restoration, suspended worker, website features, native-host behavior/performance/profile routing/snapshot freshness all passed. Native host peak RSS: 8.3 MiB.
- QA packaging, Chrome/Firefox profile isolation and development/public channel tests passed. Release readiness passed. Firefox lint: zero errors/warnings/notices. Both 0.2.25 extension archives built.
- Release app built and installed with matching executable UUID BF77B9C7-1F75-3BDB-A078-1401D6E0E88B; strict/deep codesign passed.
- Chrome's loaded heartbeat reports 0.2.25. Firefox remains permanently installed at 0.2.24.

## Required live acceptance

The Mac was locked on both computer-use attempts. An unlock request is pending. Do not label this tester-ready or physically verified.

After unlock:
1. Upload the prepared 0.2.25 Firefox archive to Mozilla, obtain/install its signed XPI, and confirm the default profile connects as 0.2.25 after restart. Signing credentials are unavailable to the CLI; use the authenticated developer portal. No Firefox signing checks may be disabled.
2. Inspect the actual overview on the MacBook: Notes/Firefox multiwindow spread, exposed previews, readable captions, hover layering, no app sheet, no missing windows, history drag/reflow, browser tab picker.
3. Rapidly click selected tabs and fresh Tab searches tabs across Firefox/Sidebery and Chrome windows; verify old search tabs stay unavailable and fresh searches cannot open websites.
4. Verify Add as you go starts only selected resources then allows new tabs, windows, apps and typed navigation; explicit bans remain blocked.
5. Exercise Timer/Checklist/Stopwatch collapse, hide/restore, drag and modifier shortcuts; optional naming, saved-slot order/delete/replay; finish by shortcut, timer and checklist while another app stays foreground.

The beta-installer test was invoked without its required prepared-kit argument and therefore did not run; it is not included in the passing checks. No public app release/update feed was changed. Unrelated working files and saved user data were preserved.
