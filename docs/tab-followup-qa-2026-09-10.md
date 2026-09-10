# Browser click and field-of-view follow-up

Logan confirmed the previous forbidden-Space swipe recovery works. That path is unchanged.

## Changes

- Consume the corresponding mouse-up and left drag after vetoing a forbidden tab mouse-down. Previously the browser still received the release half of the click.
- Include browser tab groups inside toolbars. Recognize Firefox's browser-owned extension sidebar separately from website content, and map forbidden title rows across the sidebar width. Duplicate labels remain conservative rather than granting a forbidden tab. Ordinary webpage ARIA tabs are still excluded.
- Place the rounded, semibold field-of-view heading below NSScreen's notch safe-area inset; reserve matching overview space.
- Capture previews in bounded batches of three, retaining stable window order and cancellation checks.
- Distinguish an outdated-but-connected Browser Guard from a missing connection in picker copy.

## Evidence and limits

- Installed Firefox heartbeat was 0.2.5 with no quick-selection capability. Temporarily loading the matching 0.2.8 manifest restored that capability and actual Firefox tab buttons appeared in Cmd+G.
- The temporary extension is development-only. Mozilla signing failed because AMO signing credentials are absent; persistent Firefox distribution remains blocked. Do not describe the temporary update as restart-persistent.
- Core policy tests (including ambiguous sidebar labels), Chrome/Firefox suites and browser idle tests passed. Firefox lint: zero errors, warnings or notices.
- Physical native-click prevention and zero-lag animation are not proven by source tests or AX actions. Final installed checks recorded below.

## Installed checks

- Updated heading was inspected in the installed overview: visible below the top safe inset, rounded semibold font, matching layout spacing. Preview capture uses three concurrent requests, but frame-time/zero-lag performance is not certified.
- Initial Sidebery scans found only one forbidden row. Diagnostics exposed a large accessibility tree (including hundreds of icon/group nodes) reaching the node limit before its text leaves. The scanner now skips image subtrees, deduplicates AX elements with collision-safe equality checks, permits up to 1,600 unique nodes under the existing 100ms worker deadline, and retains individually validated rectangles when another branch times out.
- Final one-tab Firefox session: 22 total extension tabs; 17 forbidden visible sidebar rows mapped, 21 static-text nodes reached. Selected row excluded from forbidden mapping. Icon-only/pinned targets and physical clicks are not acceptance-passed.
- Automated clicks still did not produce native mouse-down events, so full press/release veto remains physically unverified in both browsers. The Mac locked before the final Chrome check. Do not convert mapped-region counts into click-blocking proof.
- Temporary sessions were discarded during iterations. The last session is cleared through the normal development restart recovery after the Mac locked; no user-created intention was saved or deleted.
