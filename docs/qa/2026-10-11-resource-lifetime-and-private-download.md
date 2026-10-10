# Selected-resource lifetime, optional naming, and private download page

## Scope and release decision

Logan requested a tester version containing verified features, with the T adder
held out while its remaining acceptance cases are open. Priorities for this
change were saved replay, leaving the optional naming field, and continuing a
whitelist when one selected window/tab closes. This is a development candidate,
not a published tester binary and not a claim that all Intent bugs are resolved.

## Reproduction and cause

The old selection monitor ended an intention when any selected native window
disappeared or one browser lost its selected tabs. It did not consider surviving
work in another window, app, or browser. The new policy checks the entire explicit
selection. Persisted always-allowed/blocked defaults are excluded from that work.
An unknown browser inventory cannot establish closure. Whole-app selections are
checked only after startup readiness; replacement windows count for whole-app
selection, but unselected siblings do not count for an exact-window selection.
Blacklist and Add as you go do not end when initial selections disappear.

An intermediate installed test exposed a second issue: idle snapshot age could
suppress exact-owner presence confirmation after the final selected tab closed.
The candidate now requests fresh confirmation whenever the ordinary snapshot
lacks selected IDs. Identity, capability, disconnection, and generation checks
remain intact; this does not suppress genuine enforcement failures.

The optional name editor retained keyboard ownership after wallpaper clicks.
SelectionPanel now resigns editing on an outside click, preserves the value, and
forwards the original click. Inside clicks retain caret behavior. The regression
uses the production panel path with an attached editor, without ordering test
windows or reading daily recovery data.

## Frozen source and installed identity

- Base: `4e029f20bafb15b9e3c906b296206840d1c41327`, branch `codex/name-first-intentions`.
- Gate fingerprint: `5c54c05f0ec4fe6a560eeb7a3eb7a95b50b5ddfeea896ee5da5d36254c1069b3`.
- Gate result: `automated-pass`; gate, session, Swift, extensions, and native-host
  suites all passed. Release build passed. No acceptance row was weakened.
- Logs: `/tmp/intent-resource-name-release-gate-20261011.log` and
  `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-fb32Kz/result.json`.
- Final installed path: `/Users/loganmondi/Applications/Intent.app`, bundle
  `dev.loganmondi.intent`; installed and source executable UUID both
  `2459C5F6-977D-3DE5-9595-5CF705012104`. Strict deep codesign verification passed.
- Chrome Intent QA profile: Guard `0.2.43`, native connection verified. The QA
  profile initially lacked Guard; restored the existing matching component.
- Daily Firefox still has permanent Guard `0.2.42`; matching permanent `0.2.43`
  acceptance is incomplete. A ZIP is not evidence of a signed installed XPI.

## Installed QA, final candidate

| Case | Result and evidence boundary |
| --- | --- |
| Saved missing-tab replay | PASS: saved QA two-tab intention recreated both missing localhost URLs, ran automatically, and restored Stopwatch without reselection or a startup alert. |
| One of two selected tabs closes | PASS: remaining QA tab became active, Stopwatch continued, and restrictions remained active. |
| Last selected tab closes | PASS: rules became inactive, Stopwatch disappeared, no closure error. Normal app restoration remains separately gated below. |
| Optional name click-away | PASS: native editor accepted a QA name; wallpaper click returned focus to the panel, B toggled access mode, and the name remained unchanged. |
| T direct URL, Chrome | PASS for this case only: T opened the compact real QA browser, entered localhost URL transferred into the original tab list and was selected, Run focused that tab with active restrictions and no startup alert. Closing it cleared restrictions. |
| Final native-window/cross-browser physical matrix | NOT EXERCISED: deterministic policy regressions passed; these are not final physical/foreground acceptance. |

Two disposable localhost pages were used; their selected tabs were closed. Only
the newly created QA saved bookmark was removed; the user's existing saved slot
was preserved. Do not infer chooser reopening from direct Intent AX reads:
observing Intent can reopen its host. Chrome observation and inactive rules were
used independently for completion. No quiet-foreground acceptance is claimed.

## Website

The existing waitlist source moved to `/waitinglist`; privacy's back link follows
it. Root redirects to `/download`. The new page requires platform-authenticated
identity and the site owner's email; anonymous requests redirect to sign-in and
other signed-in users receive 404. Forged browser identity headers did not bypass
the production gate. Public waitlist and signup behavior remain available.

Source commit: `88333a3c564205a8a7b4e14f4a8ca39cbcb504e3` in the separate Sites
repository. Sites version 13, deployment `appgdep_6acac8c3a1a08191ae53b632aa366f45`
succeeded. Production `/waitinglist` and `/privacy` returned 200; waitlist demo
and back links were exercised. Owner/non-owner/anonymous local access cases and
the owner predicate tests passed; production owner sign-in has not been completed.
The browser choices default to both, recommended. Downloads are disabled until a
verified candidate exists; no stale release binary is presented as this build.

## Remaining tester gate

1. Quiet finish remains FAIL from the existing independent foreground trace:
   owned window restoration can raise a sibling or change Space. The final
   closure runs also left extension-owned Put aside placeholders visible after
   rules cleared; investigate their cleanup before calling completion polished.
2. Match the permanent Firefox Guard, then repeat core saved replay, resource
   closure, native clicks and keyboard navigation in that exact profile.
3. Complete native-app replay/modification combinations, final actual DBT
   contours, physical Caps/backtick shortcuts, interruption/reconnect, and soak
   checks. Existing deterministic suites do not replace these rows.
4. T stays outside the first tester allowlist until Firefox plus search-result,
   cancellation, immediate Run, hover and reconnect cases pass on one frozen build.
5. Publish a verified installable binary before enabling the private download
   button. Do not distribute a candidate with a known broken core finish path.
