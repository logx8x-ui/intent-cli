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
| Preset preparation | User reports reselect errors; repeated website opens also reported in other chat | Pending investigation |
| Actual-browser T view | Current implementation is separate ephemeral WebKit/DDG | Pending native approach |
| Website controls | User reports Instagram Messages only fails; YouTube not personally tested | Pending feature-by-feature checks |

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
