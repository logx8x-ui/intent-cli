# Private tester handoff checklist

Status: preparation only; do not send an old release link as this candidate.

## Before invitations

- Resolve every FAIL in the tester-readiness note; repeat on the packaged app.
- Record source commit, app version/build and SHA-256, supported macOS/hardware,
  install location, and both browser extension versions in the handoff.
- Verify one clean installation and one update retaining saved intentions.
- Supply the matching permanent Mozilla-signed Firefox extension, not a
  temporary developer add-on. Verify Chrome's persistent installation route.
- Check both permission-denied and permission-granted onboarding paths.
- Confirm the emergency release action is accessible without opening settings.
- Keep the prior known working installer and a tested recovery procedure.
- Invite three to five people first. Expand only after their first sessions
  finish with their workspace restored and no unintended browser access.

## First 15 minutes for a tester

1. Open Intent from its menu-bar icon and open Quick Focus.
2. Select one app and two browser tabs, then run a short intention.
3. Switch between the selected tabs by clicking and Control-Tab.
4. Finish using Intent's File menu. Your previous workspace should return,
   with the window and tab you were using still in front.
5. Repeat with Tab searches. A newly created search tab should work; it should
   not open unrelated websites. Existing unselected tabs should stay unavailable.
6. Repeat with Add as you go. Start with only the selected resources, then open
   another permitted app and website. Explicit bans should remain blocked.
7. Save an intention with Stopwatch or Timer. Close only its disposable test
   resources, then run the saved intention. Missing resources and its original
   modifications should return without reselecting them.
8. Try the documented physical shortcuts, then finish again and check restoration.

Do not test with unsaved important work. If restrictions become stuck, use
Intent's **File → Safety Stop — Release All Restrictions** and report it.

## Feedback to collect

Collect the app build, browser and extension version, what was selected, the
modifications enabled, expected behaviour, actual behaviour, and repeat steps.
A short recording is optional; exclude personal messages, passwords and private
pages. Ask separately whether Intent made the task easier and whether they
would choose to use it again. Reliability failures remain development work,
not a burden shifted to testers.
