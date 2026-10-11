# Spotlight selections of existing apps — 12 October 2026

## Reported sequence and baseline

Logan physically confirmed that Command-Space, Calculator search and Return in Intent's overview add the app and show the green selected icon. He is happy with that flow. His correction: searching for an already-open app may highlight it, but must not expose an X removal control. New apps genuinely staged through Spotlight or saved preparation retain their removal control. The confirmed input behavior belongs to the preceding installed build; it is not automatically acceptance of the new build.

## Cause and scope

`spotlightApps` records selection/presentation metadata for every Spotlight result. The window-card X and the staged-icon removal action incorrectly treated that metadata as ownership. An already-running app, including one without a visible window, could therefore acquire a removal action just by being searched for.

The controller now records removal provenance separately, using a fresh nonterminated running-application query at the explicit Spotlight or saved-preparation event. First origin persists through repeated searches, deselect/reselect and delayed preview refreshes; cancellation and session start clear it. Selection and native green/red outlines remain independent. The window card, icon hover X, icon accessibility action and removal handler share that boundary. A stale removal callback cannot remove an existing-app selection.

No keyboard, tab enforcement, session completion, app launching or saved-data format is changed. Existing apps are selected as before. Closed app additions remain cancellable before Run; block additions are not launched.

## Verification

Regression and installation receipts are recorded below after the final source gate. Tests use isolated QA data and production views, without starting a daily session, opening user apps or reading daily recovery state. Installed UI smoke is separate from physical Spotlight input acceptance.

The first gate (`intent-change-gate-ZfMM1J`) passed the release build but failed the new accessibility assertion. Standalone probes of the production icon found that unattached hosts and never-ordered private windows returned an empty accessibility tree, including positive controls. Those vacuous assertions were removed. The final fixture instead compares actual production bitmaps across both modes and origins: hovering an existing-app icon changes no pixels, while hovering a new addition paints its X. These 20 checks preserve foreground and create no visible windows; the original 12 selection/loading checks remain. Conditional accessibility-action wiring was source-reviewed; live accessibility acceptance remains unverified.

The next gate (`intent-change-gate-ChkmCG`) passed those rendered icon checks and the release build, then caught a controller-fixture error: the removal step intentionally refreshes the live inventory, replacing the synthetic app list. The independent existing-app case now restores that list before exercising a windowless app. No production change was needed for either fixture correction.

The final `npm run test:changed` gate passed all five selected suites (gate, session, Swift, extensions and native host) at source fingerprint `915ebef3c7ba6db0a835115638431ff8faa40d5d9d55655d9d64e9180205de85`. Receipt: `/var/folders/jb/trzpwgm90j3_s80cb4536jvr0000gn/T/intent-change-gate-IJQT1I/result.json`. The release app build and 1,612 isolated app-model assertions passed; controller coverage spans native/Firefox/Chrome selections in both allow and block modes, window and icon presentation, repeated queries, stale removal callbacks and new-draft reset. An independent final source review found no blocker within this scope. XCTest platform-path warnings from CommandLineTools were nonfatal. Automated passage does not promote pending physical/browser/focus checks to accepted.

## Installed copies and live boundary

Both explicit source installers ran sequentially after idle guards, with no automatic session start, no public packaging and no browser-store upload:

- `INTENT_LOCAL_INSTALL_NO_OPEN=1 ./scripts/install-dev.sh`: `/Users/loganmondi/Applications/Test Intent.app`, `dev.loganmondi.intent.test`, app UUID `C874B5CF-4758-3BDF-91C1-C5029651107D`.
- `INTENT_LOCAL_INSTALL_NO_OPEN=1 ./scripts/install-launch-local.sh`: `/Users/loganmondi/Applications/Intent.app`, `dev.loganmondi.intent`, app UUID `FCB56C53-8D6D-35F1-8FC0-DD78B0700F3E`.

Strict deep signature verification passed for both bundles; app and embedded helper report development/launch consistently with their bundle metadata. The source fingerprint still matches the gate after installation. Local install logs: `/tmp/intent-20261012-existing-app-x-install-test.log` and `/tmp/intent-20261012-existing-app-x-install-intent.log`.

Computer Use reopened both copies. Test Intent reached its own Accessibility/Screen Recording setup notices; its grants were not changed, so this is launch evidence only. Main Intent rendered its real overview with the existing data, app previews, saved slot, modifications and Apple Spotlight action. The overview was closed afterwards; the launch-channel owner is idle and Test Intent is no longer running. No daily intention was started in this turn. Physical Spotlight/hover and live accessibility on these new UUIDs were not rerun; Logan's earlier keyboard confirmation is retained for the baseline UUID only.

## Source publication boundary

The scoped source commit is published to `codex/selected-resource-lifetime` using a temporary-index snapshot that preserves the existing remote workflow tree and the remote-only October 6 QA note. The local branch remains `codex/name-first-intentions`. Only the five Swift paths in this fix and this QA note are included. No main merge, release tag, updater feed, waitlist deployment, permissions change or signing/notarization promotion occurs here.
