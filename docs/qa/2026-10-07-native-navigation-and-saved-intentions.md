# October 7 voice brief: native navigation and saved intentions

Baseline: `b3fec3e` on `codex/name-first-intentions`, actual Documents checkout. Existing untracked `.superpowers/` and `weppy-project-sync/` are outside this work. Head chat owns source/build/install/desktop during implementation; the other Intent chat has been notified. No waitlist changes or public release are requested.

## Implementation brief

1. **Desktop switching.** During an intention, clicking desktop thumbnails in Apple's Mission Control must work like swiping, including empty desktops. Desktops containing both allowed and blocked apps remain accessible: allowed windows stay visible and blocked windows stay hidden. A desktop left empty by hiding is still accessible. Do not block a whole desktop because a blocked app belongs to it.
2. **Control–Tab.** Preserve the browser's ordinary Control–Tab and Control–Shift–Tab behavior. Intent must not replace this with its own Command–Tab-style chooser. Browser restrictions continue to prevent access to disallowed tabs. Preserve Command–Tab, physical Caps Lock + backtick Run, and backtick-number modifications.
3. **Saved intentions.** Resolve the saved apps and tabs before starting. Reuse suitable existing targets; open missing required targets once in their intended browser/profile. An app that is not open appears as the same staged icon used for Spotlight additions, with its windows kept out of the way until Run. Do not ask the user to reselect a stale tab when Intent can restore it. Do not launch blocked targets simply because they appear in a blacklist. Retain honest, actionable feedback for real unavailable-app/profile/permission failures rather than hiding them. The other chat's repeated-website-opening report is included in exactly-once restoration acceptance.
4. **T and the actual browser.** Keep T, but replace the private DuckDuckGo preview with a compact view of the user's actual chosen browser/profile, including native address-bar suggestions, bookmarks and preferred search engine. Investigate native browser-window integration before implementation; do not present a separate WebKit session as the real browser or copy credentials/history into another engine. Any unavoidable interaction tradeoff should be asked through the normal written question UI.
5. **Instagram and YouTube controls.** Fix Instagram Messages only and all other selectable features, then test both websites in Firefox and Chrome. A checked feature is allowed; an unchecked feature is actually blocked/hidden. YouTube's existing choices are Search, Home feed, Shorts, Recommendations, Comments and Autoplay; normal videos stay allowed. Preserve current defaults unless a concrete defect requires changing the implementation.

## Working sequence and verification

Investigate, fix and verify one reported issue at a time. Read-only investigation of later items may proceed independently. Record causes and deterministic regressions below, then run the source-stable affected-suite gate after code settles. Install the matching development build and browser components, verify identities and live behavior, and publish only scoped source changes through an authorized branch. Existing unpublished workflow history is preserved.

Adjacent behavior to protect: exact current window/tab at DBT Run and Finish; deferred restoration ownership; fresh SBT cancellation semantics; named/unnamed saved intentions; saved-slot order; remembered timer/cooldown edits; scoped browser/profile identities; tab clicks; Add as you go and Tab searches; always-allowed/blocked rules; intact user windows/tabs and saved data. Tests use isolated data and disposable targets. Do not start multiple Swift builds or let another chat drive the desktop concurrently.

| Area | Initial evidence | Acceptance |
| --- | --- | --- |
| Apple Mission Control clicks | Dock AX has `mc.spaces` / `mc.spaces.list`; app labels were mistaken for blocked-window destinations; empty-desktop enforcement could refocus | Source fix, CoreSpec and full affected gate pass; active-session click acceptance pending |
| Native Control–Tab | Source routed it to `AllowedBrowserTabSwitcher` during enforcement | Custom chooser routing removed; native event pass-through and protected Command–Tab regressions pass; installed Firefox Control–Tab and Control–Shift–Tab checks pass through CUA input |
| Preset preparation | User reports reselect errors; repeated website opens also reported in other chat | Implemented and isolated regressions pass; final installed legacy-preset test exposed false closure detection, tracked below |
| Actual-browser T view | Previous implementation was separate ephemeral WebKit/DDG | Native profile presentation/navigation verified; companion Add/Cancel still requires direct input acceptance |
| Website controls | User reports Instagram Messages only fails; YouTube not personally tested | Implemented and extension regressions pass; final profile feature-by-feature live checks remain |

Physical-key, rendered browser, exact-profile and delayed-focus acceptance are distinct from passing unit tests. Carry forward outstanding permanent Firefox distribution and earlier unverified physical checks honestly; this document is not a claim of global release readiness.

## Navigation checkpoint

- Trusted Dock/WindowManager `mc.spaces` ancestry is checked before labels. Regular blocked window tiles retain the existing rejection rule. Empty desktops are exempt from both activation-driven and timer-driven recovery only for the desktop shell with no visible application window.
- Control–Tab, Shift–Control–Tab and repeat events pass through. Command–Tab still uses allowed-app switching. Control release no longer commits Intent's browser chooser.
- Independent read-only review found and then verified closure of the separate `handleActivated` blank-desktop path.
- `npm run test:changed` passed with source fingerprint `6fdefb636ed747ea84faa867d4743e1dd81f356a231d37a7e68ee03d0b4754c2`, baseline `b3fec3e`: session, Swift, both browser extension suites and native host. Evidence: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-29GvFn`.
- Swift builds limited to two workers, one build owner. Isolated tests did not use daily recovery data.
- Firefox's temporary guard had disappeared after restart. Reloaded the existing authorized development manifest through Firefox's native file picker; Firefox and Chrome heartbeat 0.2.35 confirmed fresh. This temporary Firefox installation still does not certify permanent distribution.
- Daily rules inactive; one pre-existing deferred hidden-workspace entry preserved. No active test session started at this checkpoint.

## First installed test and discovered blocker

- Development install completed: app UUID `ABB4B4EA-59CF-312D-A518-22203198D3D6`, embedded host `ED2E5B72-9422-3533-AB78-7283B17770BE`; both fresh Browser Guard connections at 0.2.35.
- Opened a disposable Firefox window with `example.com/?intent-qa=oct7-a` and `example.org/?intent-qa=oct7-b`, selected both via the actual overview and clicked Run. The session safety-stopped before navigation acceptance because a blocked Chrome window could not be identified. This is a failed live start, not a Control–Tab pass.
- Read-only AX/CG probe confirmed the discrepancy: the same Chrome window's WindowServer title was the extension title plus ` 🔊`, while AX used the page title plus Chrome/profile suffix. Firefox's blocked window had a successful minimize and restore diagnostic. Chrome had no minimize dispatch.
- Extended existing browser title normalization for the observed speaker suffix; strict frame, process and uniqueness requirements remain. New regressions cover AX/CG audio matching, blocked-window matching and ambiguous same-looking windows.
- Name-field AX click/set did not focus or fill the field under automation. A typed test name therefore reached overview shortcuts; immediately returned to whitelist mode and verified both selected tabs before Run. No saved intention was changed. This input evidence is not a claim that physical name-field clicking fails.

## Navigation retry after audio-title correction

- Full affected gate passed again with source fingerprint `77262d0366269369fb6902f5328438602b0850cca0759995c7486435b4720ba7`; evidence `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-0cUcMH`.
- Second development install: app UUID `DFEE3EE8-4B41-35B5-9247-B07963BBCF23`, matching fresh Chrome/Firefox 0.2.35. Install log `/tmp/intent-oct7-navigation-audio-install.log`.
- The same two-tab Firefox whitelist now stayed active; diagnostics confirm Chrome window 434 and Firefox original window 104 minimized successfully.
- While active, CUA Control–Tab changed the selected tab from example.org/oct7-b to example.com/oct7-a. Control–Shift–Tab returned to oct7-b. Repeated Control–Tab remained responsive. These are installed synthetic/native-UI checks, not physical keyboard acceptance.
- Synthetic Shift–backtick did not trigger the global Carbon shortcut. Used Intent Settings > File > Finish Intention instead; daily browser rules confirmed inactive. No completion screen was required. Because Settings was foreground for this command, this is not exact Firefox foreground-at-Finish acceptance.
- Actual desktop-thumbnail clicking during an intention remains to be verified.
- Follow-up naming evidence: the initially unfocused AX set reached the stored test name later, so the earlier note means no immediate visible AX focus/value confirmation, not a proven field-editing failure.

## Continued implementation: actual-browser finder and saved workspaces

- The finder now requests a normal compact window from the selected browser
  profile, with native new-tab/address-bar/bookmarks behavior and explicit Add
  or Cancel. It retains ownership of only its created tab. Initial presentation
  does not activate its companion panel; explicitly returning to Intent makes
  Add/Cancel keyboard-accessible without replacing the draft.
- Cancellation is delivered through nonblocking mailbox locking with bounded
  off-main retries. A cancel after tab movement cannot apply a late highlight,
  and an old completion cannot close a replacement finder. The native host and
  browser finder harnesses pass these ownership and cancellation cases.
- Installed Firefox 0.2.35 development finder opened a compact native window
  with the existing profile bookmarks/address bar and loaded the disposable
  example.com/?intent-qa=oct7-native-finder URL. The original user windows were
  retained. This establishes native presentation/navigation only: Add/Cancel
  live acceptance awaits the keyboard-accessible companion build. The owned
  test tab was closed after this check.
- Saved workspace descriptors now retain durable browser profile identity,
  per-run session/tab/window identity and container identity. Review stages
  missing resources; explicit Run performs fresh profile discovery before
  opening missing HTTP(S) tabs. Existing exact identities take precedence;
  duplicate URLs are matched one-to-one. Blacklist plans never launch targets.
  Durable issuance claims prevent a lost receipt or repeated Run from blindly
  creating duplicates. Ambiguous/unavailable identities are not guessed.
- The isolated core suite passed with the new saved-workspace restoration,
  finder contention/cancellation and profile migration regressions. Initial
  app compilation exposed a missing MainActor annotation on a nested restore
  continuation; that annotation was corrected before any installation.
- A prior session gate failed an old finder field's fixed 30 ms focus wait; a
  targeted retry passed without source changes. The test now drains the queued
  main-thread callback with a bounded deadline instead of relying on 30 ms.
  Its assertions are unchanged. Full gate acceptance remains pending.
- Website-feature independent review found a Chrome DNR lifetime bug: the
  expanded rule set exceeded the old fixed 100-ID cleanup range. That candidate
  remains uninstalled while cleanup, full-document Instagram routing and
  manual YouTube navigation regressions are being completed.

## Combined source gate and current installed checkpoint

`npm run test:changed -- --base b3fec3e` passed with unchanged source fingerprint
`c62f5fea1acd250594e8b9c527cde460cdb954913b786355633afc82ef447575`.
All selected suites passed: gate, session, Swift, extensions, host, release, AI,
and Firefox lint. Evidence directory:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-y7SoQt`.

The combined source includes Browser Guard 0.2.36. Instagram Messages-only has
request-stage and SPA inbox routing constrained by both source and destination
policy. YouTube playback evidence survives deliberate full-document/new-tab
navigation without granting automatic next playback. Chrome removes all owned
feature rules in 24000–24999 on replacement/Finish, including older leaked IDs;
other rule owners remain. Strict duplicate-ID lifecycle and negative-control
regressions pass. The combined matrix peaks at 437 feature regexes plus three
scope rules; actual Chrome compiled-regex acceptance remains a live check.

Installed checkpoint before website controls:
- App UUID `A346CFC9-B2B6-399D-B84E-9B54C6E5BB30`.
- Native host UUID `14233596-13FF-3016-A379-68873E1EFFEF`.
- App path `/Users/loganmondi/Applications/Intent.app`; identity
  `dev.loganmondi.intent`; native finder and saved-workspace source `f59a046`.
- Firefox development source is the primary checkout's firefox-extension;
  fresh profile snapshot now carries the persisted profile identity.
- The second live native finder opened exactly one compact Firefox window and
  its owned disposable example.com/?intent-qa=oct7-native-added tab (raw window
  773, tab 36), preserving native profile bookmarks/address suggestions.
- The native automation can target Firefox/Intent's main window but cannot
  select the separate companion panel. A single user Add-click check is pending.
  No Add/Cancel live pass is claimed.
- Chrome still runs earlier 0.2.35 code without native finder capability. Browser
  automation explicitly denied chrome://extensions navigation; no alternate
  browser surface or command was used to circumvent it. Matching reload needs
  the user's action after final installation.
- Firefox AMO is authenticated in the existing Firefox profile. Its existing
  distribution is unlisted; 0.2.36 packages are built but not signed/submitted
  or permanently installed at this checkpoint.

## Final component installation and live restore failure

- Scoped source was published to `codex/overview-finder-fixes` at
  `d8942b5fdfe89413dfc61972e7af6aa75de84388`. The branch contains equivalents of
  primary commits `b45f0bc`, `f59a046`, and `a67668c`, without the unrelated
  unpublished workflow commit. Source directories and scripts were compared.
- The earlier companion Add-click handoff was superseded. Only the owned
  `example.com/?intent-qa=oct7-native-added` tab/window was closed through the
  browser before final installation; no Add acceptance is claimed.
- Final development installation succeeded via `scripts/install-dev.sh`, log
  `/tmp/intent-oct7-final-install.log`. App UUID is still
  `A346CFC9-B2B6-399D-B84E-9B54C6E5BB30`; final embedded host UUID is
  `E7E76436-07B0-35B2-AB9C-7AA136EBC451`. Signature verification passed and both
  bundled extension manifests are 0.2.36.
- Mozilla approved unlisted Firefox version 0.2.36, version ID 6550688/file
  5094827, with zero validation errors/warnings. Downloaded signed package:
  `dist/firefox/intent-browser-guard-0.2.36-signed.xpi`, SHA-256
  `56c7a834c3213a9a078865252a677d7a4f95beb2ba99b7e87f43d2b2d3393cbb`.
  All code/assets match the validated source archive; the manifest is
  semantically identical, with Mozilla formatting/signature files added.
- Removed only the temporary override and installed the official signed update
  in `ykomjweq.default-release`. Firefox records version 0.2.36, active,
  userDisabled=false, appDisabled=false, signedState=2. No new permissions;
  private-window access remains unchecked. Fresh native heartbeats confirm
  Firefox and Chrome at 0.2.36 with native-finder/profile capabilities. A Firefox
  restart test has not been performed; the unused QA profile still lacks a
  permanent guard. This is not a public release/feed update.
- Saved the disposable recent `QA Oct7 native tab navigation` as test slot 5,
  selected Review workspace, then Run. Correlated discovery correctly migrated
  its two existing Firefox example tabs (IDs 8 and 9, window 344) without
  creating duplicates. The session then incorrectly finished after six seconds
  claiming selected tabs closed.
- Cause: an ordinary forced snapshot produced while the extension's rule view
  was inactive contains empty `tabs`/`allTabs`, overwriting normal inventory.
  The native monitor interpreted this fresh empty snapshot as closure despite
  a contemporaneous complete discovery still containing both tabs. A targeted
  app-side confirmation fix and regression are in progress; this live run is
  recorded as failed, not a saved-restoration pass. Browser rules are inactive.
- Deeper cause confirmed in Firefox's native-message listener: it awaited a
  requested tab operation before registering the message's rule update. An old
  inactive message could therefore finish after Start and revert the guard to
  idle. A listener-level delayed-command regression fails the old ordering and
  passes arrival-order rule registration. Follow-up work also fences stale
  refresh completion and asynchronous startup effects across Finish.
- The native monitor's absence confirmation uses a dedicated snapshot mailbox;
  review caught and removed an initial implementation that would have overwritten
  ordinary activation/preview commands. Complete fresh replies from every current
  owner, exact request IDs and occurrence cancellation are required. Source and
  installed acceptance for this follow-up are not yet complete.


## October 8 follow-up checkpoint

- Reproduced the .36 false selected-tab closure in the preceding live run;
  .37 registers Firefox rule revisions before awaiting commands, fences old
  refresh resolvers and startup side effects, and confirms absent tabs through
  a fresh correlated full inventory on a dedicated mailbox.
- Final review found a Finish gap: stop is requested before monitor cancellation
  and occurrence teardown. Monitor entry, delivery and continuation now require
  the same lock instance with `isStopRequested == false`. The async regression
  holds occurrence and task alive, requests stop, then delivers a late closure;
  no completion or safety decision may be delivered.
- Source-stable gate against `a67668c` passed on 2026-10-07 16:22:49 UTC:
  gate accounting, session UI, Swift, both extensions, native host, release,
  AI and lint. Fingerprint
  `d219ddbc8a70bb4b39ccdb20d898c834fb619588c0f92c4b21b8b7a45e06ae3f`.
  Durable logs: `~/.codex/artifacts/intent-20261008/final-change-gate/`
  and `final-gate.log`. Installed via `scripts/install-dev.sh`; app UUID
  `BCC68347-1848-3948-A83B-ABDDE697990D`, helper UUID
  `AD7A9A24-15AD-3B87-860F-3F3CFE25C475`. Data preserved; rules inactive.
- Firefox daily profile retains permanent signed .36 after restart. Matching .37
  raw-source ZIP byte comparison passed and Mozilla validation reported zero
  errors/warnings; unlisted version 6551904 submitted for signing. Signed .37
  installation and current-build live acceptance still pending at this checkpoint.


### Current installed live checks, October 8

- Mozilla approved unlisted .37 (version 6551904, file 5096043). Signed XPI
  SHA-256 `0660f43f632ecf097bddaa0a336b39c704ba2c11d5445e2a51293a149733b635`;
  assets/code match source, manifest semantically identical. Existing permission
  set unchanged. Daily Firefox `ykomjweq.default-release` now records .37 active,
  signedState=2, userDisabled=false, appDisabled=false; private windows remain
  unchecked. Fresh Firefox and Chrome heartbeats both .37. A post-.37 browser
  restart remains pending; this did not update the public release feed.
- Chrome Logavix was initially at the profile picker, explaining its stale
  heartbeat. Opening the existing profile restored a fresh .37 connection.
  T opened a compact normal Chrome window with this profile's native address
  bar and bookmarks. Add moved the owned example.net QA page into original
  browser window 1733681033, preserving its existing two tabs; Intent AX showed
  only the added page selected. Cancel on a second finder removed its owned
  blank tab, retained those three tabs and retained the existing selection.
- CUA initially could not bind the nonactivating confirmation panel. Read-only
  AX/CG confirmed it visible and Add enabled. CUA coordinate clicks, grounded
  in those bounds and display scale, completed both Add and Cancel. No user
  action or code workaround was needed for these two Chrome cases.
- Saved QA preset Review showed two `Opens at Run` pages and created none during
  Review. Run reopened exactly one of each missing example.com/example.org QA
  URL into Firefox window 17 (tab IDs12,13), profile
  `5f4fb4bd-90fe-4687-94ec-afa28f7491c7`. Session
  `F6F3843C-9B7D-40DA-B058-D4CB29512A08` remained active well beyond eight
  minutes, versus the prior six-second false closure. Native Control-Tab and
  Control-Shift-Tab switched between the two selected tabs via CUA.
- A simulated Shift+backtick did not end the session. Physical-key verification
  was requested with example.org active, native Firefox window107 in front.
  No successful exact-window Finish claim is made at this checkpoint. CUA's
  Dock binding also timed out while checking Apple Mission Control; physical
  desktop-thumbnail selection remains pending.
