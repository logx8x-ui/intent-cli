# Chrome T startup and actual browser tab outlines

## Reported failures

- T adds a website, but Chrome Run intermittently reports that its current
  windows cannot be confirmed and asks for Browser Guard reload/reselection.
- Double-backtick selection does not draw the actual Chrome tab outline.
- Firefox's outline includes the sidebar row spacing instead of following the
  painted tab shape.
- Adjacent installed reproduction: closing the compact T browser with Cmd-W
  leaves T and Add a website unable to reopen it.

## Changes and regressions

Chrome's tab activation and native window focus settle separately. A bounded
explicit activation owner now publishes actual populated inventory when the
later focus event arrives, even before rules are active. Explicit Run invalidates
a pending hover preview's restoration, including when both target the same tab.
It does not reactivate an already-active tab and collapse native multi-selection.
Every asynchronous query is fenced by both command and accepted-activation
revision, including queries begun before an owner exists or during validation.
Disconnects, changed rules, profile/session changes, target closure/movement and
user activation cancel the owner. No synthetic focused acknowledgement is used.

Overview Run activates only the selected raw profile's existing native parent,
bound by PID and launch identity. Composite tab and window IDs cannot borrow a
sibling process. DBT skips that transition and retains its captured foreground.

Forced idle events no longer publish a false empty Chrome inventory. The outline
reader requests its own correlated discovery receipt, validates every profile's
process lifetime, and retains confirmed inventory only briefly for the same
context. Separate Firefox parent processes remain independent. Composite IDs are
resolved to the exact raw profile before matching native sidebar DOM IDs.

Firefox uses the uniquely identified painted background inside each Sidebery
row, with conservative outer-row fallback for unavailable/ambiguous geometry.
Native labels contradicting Chrome's discovered tab order now clear stale
geometry and trigger a fresh receipt. Ordinary AX timeouts retain bounded
continuity. Regressions cover delayed focus, preview restoration, old unowned
queries, overlapping discovery, cancellation, separate processes, recycled PIDs,
reordering, pinned/duplicate tabs, sidebar spacing/indentation and clipping.

The external-close reproduction was a separate finder lifetime defect. The
browser returned a generic observation error after its owned tab closed; the app
stopped observing and kept its controller/input ownership. The exact profile now
reports a typed terminal observation only after confirming its owned tab/window
is absent or the tab has moved. It retires deletion ownership before replying,
so moved tabs and additional user tabs survive cancellation. The app calls its
existing Cancel path to release mouse/keyboard ownership. Transient failures
keep recovery controls and continue bounded observation. The real asynchronous
controller regressions cover close/reopen, late old replies and failure followed
by confirmed closure; native-host tests retain exact receipt identity checks.

## Earlier 0.2.42 evidence

Before the newly discovered cancellation defect was fixed, the frozen 0.2.42
candidate passed all eight serial change-impact suites in
`intent-change-gate-2F42rQ`, fingerprint
`789886b3a3a58fc03507cd5439cebd49e2553a11deea591f5d6ae8b7244932b3`.
It was installed at `/Users/loganmondi/Applications/Intent.app`, UUID
`0C5C9979-E4DC-30FF-B4BB-688E3BE0791D`, with matching Chrome Logavix/Default
unpacked Guard and permanently Mozilla-signed Firefox daily-profile Guard.

Two native Chrome T → direct URL → auto-transfer → Run sequences passed on that
installed candidate. One used the Run button, the other Return after deselecting
and reselecting the transferred row. Each had active rules and the exact selected
tab active in a focused window, with its URL separately verified through native
AX. Menu Finish released rules and showed no completion/save screen. These were
not continuously sampled quiet-finish passes, nor proof of hover interaction.

A read-only probe linked the production release objects and exercised actual
correlated discovery, PID/lifetime resolution and AX scanner. It resolved both
Chrome QA tabs and the daily Firefox Sidebery painted rows, including indentation
and clipping. Some background windows returned AX timeout/unavailable; no fake
geometry was invented. This proves discovery/geometry, not the physical DBT
gesture or the rendered selection border.

## Final 0.2.43 candidate evidence

The final frozen source passed all eight serial change-impact suites in
`intent-change-gate-3eni0J`, fingerprint
`b8b4b80b97f054e7a018e90422d407957ea370b70258ca9459a7ebbc17a9e657`.
The gate ran from 2026-10-09 18:11:40 to 18:13:48 UTC. It includes 400
app-model assertions and 232 presentation assertions. An independent read-only
check confirmed the source fingerprint still matched after installed QA.

The development candidate was installed at
`/Users/loganmondi/Applications/Intent.app`, bundle `dev.loganmondi.intent`,
executable UUID `97FDE7AE-16FF-39EE-A65D-0DB8218EA16C`. Strict deep ad-hoc
signature verification passed. That is development-install evidence, not Apple
notarization or a public binary release. The embedded native host and Chrome
Logavix/Default Guard are 0.2.43. The permanently signed daily Firefox Guard
remains 0.2.42; final Firefox 0.2.43 acceptance is pending.

Three native Chrome T → direct URL → auto-transfer → Run sequences passed on
the installed 0.2.43 candidate. Runs 1 and 3 used the Run button; run 2 used
Return. Each transferred exactly one tab to the intended parent window and
selected it. After Run, active rules contained that exact tab ID, its actual
profile inventory reported it active in a focused window, and a separately
refreshed native Chrome AX binding showed its URL. The startup-failure record
was unchanged and no reload/reselection alert appeared. Target IDs were
1733681401, 1733681410 and 1733681416 in parent window 1733681378.

Before runs 1 and 2, Cmd-W closed the owned compact T window and T reopened it
in the same overview. One intermediate automation click was routed to a stale
native window binding; refreshing the Intent binding restored the intended
action. This is recorded as an automation limitation, not a passed app gesture
or a new app defect. Asynchronous controller regressions additionally cover
immediate cancellation before opening and cancellation during commit.

Each test ended through Intent's File → Finish Intention after Settings was
explicitly opened to expose the native menu host. Rules became inactive and
no save/completion screen appeared. Because that deliberately changes the
foreground before finishing, these are cleanup checks, not quiet-finish passes.
Only the owned disposable test tabs were closed; user tabs and saved intentions
were preserved. Intent was left running with inactive rules.

The authenticated Firefox upload page remained accessible, but supported native
HTML interactions did not open its file chooser; another supported activation
route timed out. The 0.2.43 signing/install step is incomplete. No login/session
credentials were guessed or copied to another browser, and the old signed
extension is not represented as final matching-profile acceptance.

## Source publication verification

Primary fix commit: `036c580`. Its source was cherry-picked as `028663d` onto
`codex/overview-finder-fixes` without changing the public branch's workflow.
The only tree differences from the primary commit are that existing workflow
and the existing source-publication note. Runtime source, tests and manifests
match. Because the complete tree differs, the publication branch received its
own eight-suite serial gate: `intent-change-gate-9lQs5b`, fingerprint
`0e14b8ad8acdfcbaba92a1e5eda943e680c1f230a5077c68e302de464031b08f`,
2026-10-09 19:07:06–19:08:35 UTC, all passed without source drift.

The first publication run stopped at a missing local `addons-linter` executable
after seven suites passed. `npm ci --ignore-scripts` installed the locked
dependencies; the full gate was then rerun, rather than relabeling that failure.
The npm audit separately reports 16 findings in the existing `web-ext` tooling
dependency tree (3 critical). These tools are not bundled into the Swift app;
their maintenance is still open and is not certified by the functional gate.
No forced dependency upgrade, update feed or public binary release was made.

## Outstanding acceptance

The current-build physical double-backtick/Caps Lock/held-number path and actual
rendered tab borders require their own evidence. An overview selection, synthetic
shortcut or read-only AX geometry probe is not a substitute. The known quiet
completion foreground jump remains open; visibility restoration does not prove
continuous foreground preservation. No public binary release or tester-ready
claim is made by this source change.

The three Chrome direct-URL runs do not certify search-result transfer, a live
hover/Run race, reconnect, saved replay, browser rule matrices or social controls
on the final candidate. Those remain separate acceptance rows.

The next defect loop and private tester gate are documented in
`2026-10-10-stabilization-plan.md`.
