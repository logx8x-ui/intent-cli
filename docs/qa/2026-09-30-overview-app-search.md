# Overview app search and immediate dismissal — 2026-09-30

## Change

- Inside the overview, backtick opens an app-only search using installed bundle URLs and icons; type a name and Return adds the visible highlighted result. This is Intent's integrated search, not a replacement claim about Apple's native Spotlight.
- The first selection retains its app while the in-overview name bar is completed. Existing named drafts add immediately. No modal name loop on this path.
- Always-allowed and always-blocked presets are excluded from app-search results and the main grid.
- A newly added app keeps its icon card while asynchronous preview batches complete; an unopened app need not expose a native window to remain selected.
- Escape dismisses the entire overview immediately, including text editing, modifier settings and stack views. Held backtick + Escape retains clearing semantics. Closing cancels pending capture/resolution/mark tasks and clears popover state.
- Held backtick number shortcuts remain independent of app-search text focus; query submission cannot accidentally start an intention. Arrow navigation is bounded to visible results.
- Native Cmd+Space lowers the overview below Spotlight. Native Spotlight's marker is left intact during typing and stripped only on marked submission; uncertain result identities still fail safely.
- Background-preparation failure retains the selection and shows overview status instead of opening another blocking alert. The first-use notice uses a sheet in the overview.

## Verification

- IntentCoreSpec passed, including 100 repetitions of overview prefix, successive modifier numbers, autorepeat, release after focus changes, ordinary app-name typing, immediate Escape while editing, and held-prefix Escape clear/close. Existing global gesture, layout, profile and session specs also passed.
- Release Intent/IntentApp/IntentNativeHost built and scripts/install-dev.sh installed/relaunched the development copy using the compatibility linker (`-Xlinker -ld_classic`).
- Live UI: backtick opened the app-search field; Calculator returned a real app result; Return retained the choice through naming; Calculator appeared as selected in the main grid. Notes then added to the same named draft without another name prompt and both Notes windows showed selected.
- Live UI: Finder returned no matching apps while remaining in the bottom-left preset strip.
- Live UI: Escape, settings dismissal and Close were exercised. Inspection can reopen this accessory app; physical keyboard dismissal latency remains a separate acceptance check, not an asserted universal guarantee.
- Apple's native Spotlight surface could not be inspected: the computer-use tool timed out for com.apple.Spotlight before and after lowering the overview. Native marked-result submission remains unverified; integrated overview search is verified independently.
- Calculator's initial background hide was rejected by macOS; selection remained valid. Do not describe all application background launches as verified.

No intention was started or saved by these checks. No waitlist or browser-extension source changed. Permanent Firefox store-update status is unrelated and remains pending.
