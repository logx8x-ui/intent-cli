# Missing native launch date: iLoader

Reported surface: a normal intention stops with the excluded-app visibility
notice. Expected: ordinary excluded apps can be hidden and later restored even
when NSRunningApplication omits their launch metadata. Preserve fail-closed
verification, exact process lifetime, durable ownership, and existing controls.

The daily launch diagnostics had `inventoryUnavailable`, zero unresolved hide
targets, and `missingIdentityPIDs=[65129]`. That PID belonged to iLoader.
A direct public API probe confirmed AppKit launchDate=nil while
proc_pidinfo(PROC_PIDTBSDINFO) returned a complete matching PID and birth time.

NativeProcessLaunchDate preserves the existing AppKit identity when available
and falls back to the kernel birth timestamp only when missing. Invalid PIDs,
incomplete responses, PID mismatch and invalid timestamps return nil. The
visibility controller uses the same resolution for startup, effects, lifetime
checks and journal restoration; no app is exempted and no guessed date is used.

Added behavioral checks for actual kernel birth time, stable repeated reads,
invalid PIDs and an exited child process. Gate receipt:
`/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-MKsZ4t/result.json`.
All five mapped suites passed: gate, session, Swift, extensions, host. The session
suite includes the release app build. An earlier run lost the isolated notch
test's activation during concurrent UI inspection; the serial rerun passed.

Installed using scripts/install-dev.sh --launch-local. Source and installed app
UUID both DEA9ABCF-9322-32D3-BD3B-EDC35795FC2E. This is the existing local launch
QA channel, not a newly signed/notarized public artifact. Test Intent unchanged.

Installed live ChatGPT-only overview run: native visibility phase=resolved,
inventoryAvailable=true, missingIdentityPIDs=[], unresolvedCount=0; iLoader
positively hidden. Enforcement becameReady=true, phase=enforcing. Later daily
diagnostics recorded manual finish, inactive browser rules, and empty owned
workspace journal. Exact physical tab outlines and all-Space foreground/window
restoration were not newly certified by this check. Downloads remain gated.
