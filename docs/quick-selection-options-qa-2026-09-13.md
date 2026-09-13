# Cmd+G restrictions and frictions

The bottom of the field of view now has Restrictions and Frictions pills with
selection counts. Either opens a glass panel on the left. The window layout
reserves space beside the panel, and the panel scrolls within the screen height.
Escape closes the panel first, then the overview. Clear resets resources and
options while retaining Allow/Block mode. Typing `/` in a phrase or checklist
does not switch modes.

Restrictions include timer, end time, browser searches, cooldown, and Don't
start up. Timers and end times expose a separate lock toggle, initially off.
Exact-tab Allow mode keeps searches within selected tabs; it does not silently
allow additional tabs. Cooldown applies when replaying the saved intention.
An explicit Don't start up choice survives saving, independently of the
automatic suppression of duplicate launches for the current session.

Frictions include typed phrase, countdown, reason prompt, checklist and time
budget. Selected cards show their step number and editable settings. The normal
start flow collects an end time, runs frictions in order, then starts the lock.
Cancelling clears pending Quick Focus state. Exact tabs are revalidated after
the preparation steps. Browser disconnection or closure of the selected tabs
releases the session even when manual finish is disabled by a timer.

The save prompt reports restriction and friction counts. Save keeps the chosen
settings, only removing the automatic current-session startup suppression.

## Automated checks

- IntentCoreSpec passed: both access modes, timer/lock/end-time semantics,
  cooldown, ordered frictions, serialization, distinct explicit/automatic
  startup suppression, and empty-friction rejection.
- Firefox/Chrome rule and background tests plus idle/reconnect checks passed.
- Debug build passed; release build and data-preserving development installation
  passed for the initial live test.

## Live checks

- Opened the installed Cmd+G picker, selected restrictions and frictions, and
  visually inspected both panels. Previews move to the right; controls remain
  inside the display and clear of previews.
- Edited a phrase containing `/`; Allow mode did not change. Switched to Block
  using the footer and selected Preview; options and counts were retained.
- Start presented the selected end-time dialog, then the exact typed phrase,
  then the second friction. Cancel returned safely to Intent.
- This test caught an existing SwiftUI state-reuse bug: countdown after a phrase
  initially displayed zero. Friction sheets now use the pending step's identity
  to reset input, checklist and countdown state between steps.

## Corrected-build verification

- Rebuilt release and installed again; deep/strict app signature validation passed.
- Escape collapsed the panel while preserving selected options. `/` outside text
  input switched mode; the edited phrase still contained its literal slash.
- Configured Preview in Block mode, a one-minute timer with manual finish
  unlocked, explicit Don't start up, typed phrase, and a ten-second countdown.
- The phrase gate disabled Continue until the exact input was supplied. The
  second step then started at **10**, with Start disabled, and reached **0**
  before enabling Start. This directly verifies the state-reuse regression fix.
- Start displayed the active Quick Block timer at **01:00**.
- At expiry the session ended automatically and displayed the save prompt with
  **2 restrictions / 2 frictions**. Saved the test and inspected its JSON: the
  one-minute timer, explicit Don't start up resource, exact typed phrase and
  ten-second countdown were preserved; the automatic startup node was removed.
- Removed only the created QA intention through the normal graph editor, then
  confirmed the original 12 saved intention IDs were all preserved.
- Full-screen visual checks were on the current display; other display sizes
  and physical browser-disconnection recovery during a locked timer were not
  exercised live. The earlier Firefox permanent-signing limitation is unchanged.
