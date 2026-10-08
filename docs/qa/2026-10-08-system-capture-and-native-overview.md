# Native capture and Apple overview follow-up — 2026-10-08

## Reported sequence

- During an intention, Apple's Mission Control shows an allowed Firefox window,
  but clicking it does not enter the window; swiping to it works.
- System screenshot shortcuts must work without adding Screenshot to the
  intention or its persistent always-allowed list.

Adjacent protected behavior: ordinary forbidden browser input remains inert;
Control-Tab stays native; Command-Tab, Space navigation, fresh Tab searches and
backtick controls retain their existing routes. Run and every Finish still
preserve the exact foreground window/tab. This change adds no activation on
Finish and does not edit the selection gesture owner.

## Confirmed capture defects and scoped change

The browser shortcut policy already allowed Command-Shift-3/4/5, but the earlier
whole-window input mask could consume these keys before that policy ran. Native
capture now passes before session shortcut handling and the shared inert-window
decision also exempts it. Clipboard modifiers remain available; 6 retains the
native Touch Bar capture shortcut where supported.

The on-disk system bundles are `com.apple.screenshot.launcher` at
`/System/Applications/Utilities/Screenshot.app`, and `com.apple.screencaptureui` at
`/System/Library/CoreServices/screencaptureui.app`. Only these exact identities
are system-tool exemptions. They are not added to saved app lists. Capture is
excluded from initial application hiding, window restrictions and focus
recovery; when its UI is frontmost, its drag, Space, Return and Escape input
remains owned by macOS.

`SystemCaptureRegressionSpecs` exercises the real inert-window policy, including
the previously earlier swallow with a blocked-window probe, both modes,
clipboard variants, initial hiding, window rules, focus and click decisions.
It also checks that ordinary app/input restrictions retain their behavior.

## Native Mission Control identity

Read-only live Dock Accessibility inspection found `mc` → `mc.display` →
`mc.windows` → one AXButton named `Example Domain`, with no app URL/identifier,
at x173 y134 width1364 height856. Dock's AXApplication has title `Dock`. The
existing resolver mixed free window titles and owner/container labels while
searching for a running app name; neither source is a window's app identity.

The native overview path now accepts only an explicit local app-bundle URL from
the tile's bounded ancestry, stops at window/display/application containers and
does not infer an application from window-title text. Unknown identity passes
through to macOS while existing exact app/window visibility and enforcement
remain authoritative. Ordinary Dock app icons keep their original app-name
route. `MissionControlRepresentationSpecs` covers the observed title, misleading
Messages/VS Code labels, owner ancestry, an actual forbidden app-bundle fixture,
Space navigation and independent window restrictions.

A CUA click on the observed tile left `mouseDownEvents` and
`missionControlEvents` at zero. It therefore did not establish event-tap delivery
or physically reproduce/pass this bug. Physical native-window click acceptance
remains pending.

## Evidence status

- Source inspection and `git diff --check`: passed.
- Isolated automated gate: pending root's serial run.
- Matching installed build and native capture selection/cancel: pending.
- Apple Mission Control identity source correction: implemented; isolated gate
  and physical allowed-window click acceptance pending.

Live capture checks should include Command-Shift-3/4/5, Control clipboard
variants, region drag, window capture via Space, Escape cancel, screenshot
toolbar capture and the same commands while a browser has no permitted tabs.
