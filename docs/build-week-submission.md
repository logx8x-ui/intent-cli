# Paste-Ready Build Week Submission

## Project Name

Intent

## Tagline

Choose one thing. Let everything else wait.

## Track

Apps for Your Life

## Short Description

Intent is a native macOS focus app that makes the computer honor one chosen
purpose at a time. Each intention visibly defines its allowed apps, websites,
restrictions, and friction. When it starts, Intent opens the required
environment and keeps unrelated apps, windows, sites, and tabs unavailable
until the session ends. GPT-5.6 can turn a plain-English description of the
person's work into editable intention drafts using apps actually installed on
their Mac.

## Inspiration

I kept opening my Mac for one shallow task, such as replying to an email, and
losing the original intention among unrelated tabs and apps. Existing focus
tools still left the distracting choice in front of me. I wanted to make the
choice once, before the session, and have the computer keep that promise for me.

## What It Does

An intention is a reusable computer environment. Its square contains allowed
apps, browser markers represent allowed websites, circular nodes add
restrictions, and triangular nodes add deliberate friction such as a typed
commitment. Starting one opens the allowed resources and activates native macOS
and browser-level enforcement. Intent also provides allowed-only app and tab
switchers, timers, cooldowns, a scheduler, and a universal `Cmd+Shift+M` exit.

The optional AI builder asks what the person needs to do. GPT-5.6 returns
specific intention drafts with installed apps and narrow website suggestions.
The person reviews and edits every resource before import; nothing is started
automatically.

## How It Was Built

The desktop app is written in SwiftUI and AppKit. macOS Accessibility and event
APIs enforce app and window boundaries. Firefox and Chrome extensions enforce
tab and URL rules and communicate with the desktop app through native messaging.
Intentions and schedules are stored locally as structured JSON.

The AI path is a Cloudflare Worker that calls GPT-5.6 through OpenRouter. It uses
strict JSON Schema output, validates requests and responses, rate limits by
installation/client, and keeps the API credential out of the distributed app.

## How Codex Helped

Codex was the engineering partner throughout the Build Week sprint. It helped
trace failures across Swift, Accessibility event taps, browser extensions, and
native messaging; implement the spatial graph and adaptive-glass UI; create the
scheduler, switchers, timers, cooldowns, and AI review flow; add regression
tests; and repeatedly build, install, inspect, and package the real app on the
target Mac.

The most valuable workflow was the tight observe-trace-patch-test loop. Instead
of producing a disconnected prototype, Codex worked inside the existing codebase
and helped turn real failures into focused fixes.

## How GPT-5.6 Helped

GPT-5.6 powers the optional intention builder. Given a description of the
person's activities and a catalog of installed apps, it returns two to eight
specific reusable intentions in strict structured output. The model may only
select real bundle identifiers from that catalog. Its output is validated and
presented as an editable draft, so the model proposes while the person remains
in control.

## Challenges

The hardest boundary was that macOS and browsers expose different levels of
control. Native event APIs can govern application focus, but reliable tab and
URL control belongs inside each browser. Intent therefore needed one coherent
session contract enforced by three cooperating pieces: the Mac app, the browser
guard, and the native-messaging host. Preserving normal interactions such as
closing allowed tabs, Mission Control, screenshots, and the universal exit while
blocking only the disallowed path required repeated real-device testing.

## Accomplishments

- Turned a CLI prototype into a native spatial macOS product.
- Built one rules contract enforced across macOS, Firefox, and Chrome.
- Made restrictions visible and editable rather than hiding them in settings.
- Added a hosted structured AI builder without asking users for API keys.
- Produced a friend-testable release, automated regression tests, and simple
  download paths.

## What Was Learned

Focus software is less about blocking everything than preserving the exact
normal interactions that still belong to the chosen task. The product became
clearer when each rule was visible on the canvas and when AI was treated as a
drafting partner rather than an authority.

## What's Next

Next steps are permanent store listings for both browser guards, Apple Developer
ID notarization, Windows support, calendar integrations, richer scheduling, and
optional sync while retaining local-first intention data.

## Links

- Repository: https://github.com/logx8x-ui/intent-cli
- Release: https://github.com/logx8x-ui/intent-cli/releases/tag/v0.7.0
- Demo video: PASTE PUBLIC YOUTUBE URL
- Codex Session ID: RUN `/feedback` AND PASTE THE ID

## Final Submission Checks

- The YouTube video is public and shorter than three minutes.
- The repository is public and includes the MIT license.
- The demo has spoken audio explaining the product, Codex, and GPT-5.6.
- The `/feedback` Codex Session ID is included.
- The submission is sent before 8:00 AM Australia/Perth on July 22, 2026.
