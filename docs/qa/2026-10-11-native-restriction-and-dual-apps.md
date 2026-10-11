# Native restriction recovery and two local apps — 11 October 2026

## Report and observed evidence

Logan reported that a ChatGPT-only intention allowed an ordinary app such as Spotify. Computer History was running when inspected at 11:26 UTC. The relevant journal and history show short ChatGPT-only occurrences around 10:46 UTC, followed by a separate QA occurrence from 10:54:50 to 11:25:32 UTC. The latter became a recovery checkpoint. An Intent-owned alert subsequently said all restrictions had been released by a safety stop. Spotify playback interactions at 11:26 occurred after that termination.

This establishes an interrupted restriction session; it does not establish the exact old-build stop cause. A sparse Spotify event during the QA occurrence may have been our automation. Do not attribute it to physical user input. Another visible ChatGPT window ID in the restoration trace does not prove the selected window was replaced or closed.

Source inspection found two concrete flaws independently of that uncertainty:

- Native startup readiness could be reported before the first native hiding pass had been confirmed.
- One failed Accessibility raise of a selected window, followed by one failed fallback, could release the entire intention without proving that selected work had closed.

## Changes and regression safeguards

- Restrictive startup waits for confirmed native visibility coverage. Already-hidden/minimized user state is not claimed as an Intent effect. Unknown observations cannot establish successful hiding or window closure. A bounded coverage failure prevents a false successful start.
- Selected-window recovery retains the original rules, coalesces retries, and uses a bounded recovery episode. Confirmed resource exhaustion follows the existing normal lifetime monitor. No replacement or unselected window is newly authorized.
- Recovery binds the selected native window to one unique live Accessibility object and process birth, revalidating permission before each effect. An invalid or rejected window raise never falls back to activating its app. Both asynchronous remembering and direct scoped raising use this boundary.
- Potentially blocking refocus effects run outside the input callback, are coalesced, and remain cancelled after finish. Input-protection interruptions have a typed failure reason rather than successful completion.
- Manual finish and timer expiry keep their original outcome even if a delayed cause-only safety callback arrives afterward. Regression checks exercise those callbacks against both terminal paths without installing an input tap or changing windows.
- The latest occurrence writes a bounded, content-free `focus-enforcement-diagnostics.json`: enforcement phase, readiness, input tap state, blocking counters and first stop cause. It contains no app/window/tab/intention titles.
- Startup additionally writes bounded `native-visibility-diagnostics.json` readback evidence (PIDs, window IDs, operation outcomes and missing identity), without names, titles or URLs. Permitted apps with no excluded windows need no process birth identity; actual excluded targets still require it.
- Finish laser travel is 0.86 seconds, total presentation 1.18 seconds; the core is 1.2 points with a 210-point tail. It remains nonactivating and transparent to input. Reduce Motion remains static.

## Separate installed identities

| App | Bundle | Data | Channel |
| --- | --- | --- | --- |
| Intent | `dev.loganmondi.intent` | `~/.intent` | launch policy; experimental T adder excluded |
| Test Intent | `dev.loganmondi.intent.test` | `~/.intent-test` | development policy; T adder retained |

Test receives a one-time copy of durable saved data and completed history, excluding authentication, unfinished sessions and runtime effects. Test uses a local workspace without cloud sign-in. Only one engine owns global input/window effects/native messaging. Lease generations fence stale native hosts; active sessions and preparation prevent handoff. Idle installers do not replace an active engine.

Both installers use separate scratch directories and two compile jobs. Their Bash 3 empty-array invocation is covered by executing the actual build command with a stub compiler, including development arguments and a scratch path containing spaces. Old idle native helpers from the exact target installation are retired before replacing their executables; other-channel helpers and active engines are excluded from that operation.

## Installed failure caught during acceptance

The first launch-policy retry selected all four ChatGPT windows, kept Add as you go off, and used a one-minute Timer. It stopped before readiness after about 3.76 seconds with `nativeWindowEnforcementFailure`; the input tap was installed and neither timed out nor disabled. The alert was dismissed after the temporary attempt. This was not recorded as a passing test.

Investigation found a false inventory failure: Finder is a regular process on this Mac with no `NSRunningApplication.launchDate`. The original coverage pass demanded that metadata even when Finder required no visibility effect. The corrected pass determines exemptions and actual excluded targets first. Five action-selection assertions cover this boundary, while unknown identities for excluded targets still prevent readiness. Installed verification of this correction is required below.

The next installed retry confirmed that inventory became available, but still failed before readiness: Spotify rejected `NSRunningApplication.hide()`, and an excluded ChatGPT WindowServer surface had no usable Accessibility window binding. Firefox and Chrome were confirmed hidden. This retry also stayed in ChatGPT after safe release. It does not count as successful blocking acceptance. These exact failures require a verified, reversible window fallback and a precise user-window classification boundary; actual excluded user windows must not be exempted merely because Accessibility is unavailable.

The fallback journals a supported AXHidden effect before dispatch and verifies its readback. If both application-hide paths fail, it requires a complete, uniquely bound real-window cohort and confirms every owned minimization. Unreadable, ambiguous, unsettable or unclassified substantial windows remain unresolved. Restoration tries nonactivating native/AX reveal, retaining ownership until visible readback; window effects restore only the minimization owned by Intent.

A potential backing surface is excluded only when it is untitled, stable, positively offscreen, never previously identified as a user window, and absent from a complete Accessibility inventory whose real windows all bind uniquely to different native identities. Malformed or duplicate WindowServer identities cannot establish absence. The classification is checked afresh; it cannot exempt a surface that later becomes visible or readable.

The third installed attempt (UUID `6424E06A-AA57-3222-A11F-0983364C573A`) confirmed Spotify's complete one-window minimization fallback. It still stopped before readiness after about 3.5 seconds: ChatGPT's untitled surface had incomplete Accessibility inventory, and computer-control panels appeared after selecting the two visible main windows. The panel minimize dispatches returned success but minimized readback stayed false. This also is not passing acceptance. Geometric inventory must be separated from minimization capability, and any auxiliary allowance must use positive type and exact scoped ancestry rather than titles.

## Acceptance record

The final scoped native policy fixture passed 109 assertions. The exact-window recovery fixture passed 24 deterministic assertions covering delayed sibling samples, PID/birth/bundle mismatches, ambiguous geometry, failed raises, and cancellation/identity invalidation between effects. Independent read-only review found no remaining material source issue. These are source checks, separate from installed behavior.

Geometric Accessibility inventory no longer requires minimization capability. Auxiliary permission requires an AXWindow positively typed as an AXSystemDialog or AXFloatingWindow, exact process lifetime and native binding, and a permitted window ancestor or an exact application parent with live permitted standard work. Explicit app/window bans retain priority. Standard and unknown windows stay restricted. Foreground guards share only a one-second proof cache; the utility never becomes selected work or a recovery target. Stop clears the proof.

Spotlight additions commit their selection before asynchronous preparation. Allowed app icons use a transparent, icon-sized green outline; block selections use red. Whole-app native outlines use the same selection scope. Deselect/reselect, late inventory refresh and X removal preserve the intended state. The production offscreen renderer passed 12 pixel assertions; the combined session gate exercises 44 additional selection/scope assertions. Actual Apple Spotlight input and installed rendering require their own acceptance evidence.

Final automated gate, installed UUIDs, local channel smoke checks and unresolved physical acceptance are recorded below after installation. These apps are local ad-hoc-signed QA builds, not public notarized downloads. Do not enable the website catalog from this record alone.

The combined eight-suite gate passed on unchanged source, fingerprint `0e13dcf30637d647bed6986bd31fa13eb4d2fbe215f0f5b7aab942bb1a83eba0`, receipt `intent-change-gate-KJyCCT`, completed 14:15:28 UTC. Gate, session, Swift, extensions, host, release, AI and lint all exited 0. The isolated app model passed 1,544 assertions. The CLI tools emit an XCTest platform-path warning, but the compiled executable spec and all required suites completed successfully.

Installed launch UUID `3E0AFEF5-43F5-3D57-A31D-EC60550E62EB` passed strict signature verification; both app and native host report `launch`. A one-minute ChatGPT-only intention selected exact windows 4756/4766, reached confirmed native readiness after about 1.15 seconds, and completed normally at timer expiry with no input-tap interruption and zero remaining restoration entries. Spotify's complete one-window fallback was confirmed; the untitled offscreen native surface passed the full backing-surface proof. The first Spotify open landed after expiry, so it is explicitly excluded from blocking acceptance.

A subsequent three-minute ChatGPT-only run reached readiness. During that occurrence, a Finder Open action attempted Spotify activation; the health record stayed `enforcing`, showed two blocked activations and no tap timeouts/disables, and passive foreground readback was `com.openai.codex`. This is actual installed activation/recovery evidence through supported UI automation; it does not establish physical key/trackpad or exact-current-window acceptance.

That three-minute occurrence completed at expiry (14:25:33 UTC), retained the expiry result, reported no input interruption and cleared all six restoration entries. Passive foreground readback immediately before and after expiry remained `com.openai.codex`; no completion screen or safety alert appeared. Journal retirement depends on the owned visibility readback, but exact current native-window identity and physical finish-shortcut acceptance remain separate.

The separate Test build (initial final-source UUID `1DBAFD31-6A0F-317F-8C1C-1EDD6C65361B`) passed strict signatures and both executable channel diagnostics reported `development`. Its own Screen Recording permission is missing. Opening it showed the permission notice; no OS grants were made. A live idle handoff back to the launch app succeeded. Acceptance caught the notice incorrectly saying Intent rather than Test Intent; shared channel-aware permission/onboarding wording fixes this, with 39 compiled assertions for each channel. Later has no retry scheduled in the inspected source; app-bound automation did not establish a physical modal-dismissal loop.

Apple's actual Spotlight opened from the launch overview and showed Calculator as its selected application result. The app-targeted automated Return did not add Calculator to the Intent selection; Calculator subsequently ran and the status record did not provide a retained intercepted-submit receipt. This is not Spotlight submission or installed green-icon acceptance. App-targeted input may bypass the global keyboard path, so a physical Command-Space/search/Return check was requested. No internal controller invocation or synthetic selection is substituted for that result. The render/controller assertions remain valid independent evidence.

After the permission wording repair, all eight suites passed again on unchanged source: fingerprint `910f15251882b465ef0db03098a97d253a0085331e0b11ec8d151c5a80e9808c`, receipt `intent-change-gate-YZIspZ`, completed 14:39:02 UTC. The repair changes permission/onboarding copy and retains the verified native enforcement implementation. The temporary Calculator process opened during the automated attempt was closed through supported UI without editing its contents.

Both final builds were installed successfully after that gate. Intent at `~/Applications/Intent.app` has UUID `9092EEDD-6C25-3581-9E76-BA9A1B43717E`; Test Intent at `~/Applications/Test Intent.app` has UUID `18CDF2F7-C959-3FFA-97D8-093ADD5F95D6`. Both passed strict signature verification and their app/native-helper diagnostics reported the appropriate launch/development channel. The final Test notice visibly names Test Intent and Test Intent.app; no OS permission was granted. Supported Finder Open actions then handed the idle engine back to the final launch build, whose overview was visible with no active intention and all modifications off. The app-bound Later action again produced a new notice; because those actions can reopen an accessory app, this remains an unaccepted physical dismissal path rather than a claim that the installed modal behavior passed.

Outstanding acceptance: physical Apple Spotlight submission/green selected icon, Test Intent's independent OS grants and live enforcement, physical finish and gesture paths, exact current window/tab focus, matching installed Firefox component (installed 0.2.42 versus packaged 0.2.43), public notarization/signing and browser distribution. The source push and these local QA installations do not release a public download.
