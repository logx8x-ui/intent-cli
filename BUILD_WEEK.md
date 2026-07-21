# OpenAI Build Week Submission

## Project

**Intent** makes a computer honor one chosen purpose at a time. A person starts
an intention, Intent opens the required apps and websites, and unrelated apps,
windows, sites, and tabs stay unavailable until the session ends.

**Track:** Apps for Your Life

**Tagline:** Choose one thing. Let everything else wait.

## What Changed During Build Week

Intent began as a personal macOS CLI prototype. The meaningful Build Week work
between July 13 and July 21, 2026 turned that prototype into the current
friend-testable product:

- a native spatial graph canvas for intentions, restrictions, and friction;
- the adaptive glass menu-bar overlay and editable visual intention builder;
- Firefox and Chrome browser guards with native messaging;
- allowed-only app and browser-tab switchers;
- timers, cooldowns, startup controls, keyboard controls, and a scheduler;
- first-run guidance, customizable backgrounds, packaging, and GitHub releases;
- a hosted GPT-5.6 intention builder with structured output and local review.

The dated Git history provides the implementation trail, including commits
`e92a37f`, `f684964`, `16673dd`, `080edb4`, `57820b5`, and `6424877`.

## How Codex Was Used

Codex was the engineering partner across the Build Week sprint. It helped:

- inspect and refactor the Swift architecture rather than replacing it;
- implement and repeatedly debug macOS Accessibility and event-tap behavior;
- build and test the Firefox and Chrome extensions plus native-messaging bridge;
- translate the spatial UI direction into SwiftUI and AppKit interactions;
- add focused regression tests for browser rules, AI contracts, and session logic;
- package friend-testable releases and keep release instructions current;
- pressure-test product decisions against the three-minute demo and judging rubric.

The highest acceleration came from tight implementation loops: observe a real
failure, trace it across app/extension/native-host boundaries, patch it, rebuild,
install, and test again on the actual Mac.

## How GPT-5.6 Is Used In The Product

The prompt at the bottom of Intent asks what the person needs to do. GPT-5.6
turns that description into two to eight focused, editable intention drafts.
It receives an installed-app catalog, must choose only real bundle identifiers,
and returns strict structured JSON containing names, purposes, apps, websites,
and whether browser research is appropriate.

The model proposes; the person remains in control. Every app and website is
validated locally and shown for review before import, and no generated intention
starts automatically. The hosted service uses rate limiting and does not expose
an API key in the desktop app.

## Product And Engineering Decisions

- **Manual remains first-class.** AI is optional and never replaces `I`, `R`, or
  `F` editing.
- **Rules are visible.** The graph makes the allowed apps, sites, restrictions,
  and friction legible before a session starts.
- **Browser control lives in extensions.** Native macOS APIs handle apps and
  windows; browser extensions handle tabs and URLs where they have authority.
- **The lock is reversible.** `Cmd+Shift+M` is the universal finish shortcut.
- **Local by default.** Intention data and schedules remain on the Mac. Only an
  explicit AI request sends the typed description and installed-app names and
  bundle identifiers to the hosted service.

## Submission Checklist

- Public repository: <https://github.com/logx8x-ui/intent-cli>
- Release downloads: <https://github.com/logx8x-ui/intent-cli/releases/tag/v0.8.0>
- Demo guide: [`docs/build-week-demo.md`](docs/build-week-demo.md)
- Paste-ready submission: [`docs/build-week-submission.md`](docs/build-week-submission.md)
- License: MIT
- Manual step: run `/feedback` in the primary Codex task and add the returned
  Session ID to the Devpost submission.
