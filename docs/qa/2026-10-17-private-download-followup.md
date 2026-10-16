# Private download follow-up — 17 October 2026

This continues the 0.9.7 / 202610160004 candidate checks. It does not qualify the
candidate for testers. Runtime base before the work in this note is `863b08b`;
the candidate itself contains runtime `bc9be7a`.

## Reproduction and adjacent behaviour

Logan physically reported that the repaired rcmd / Mission Control check stayed
running and excluded apps stayed blocked. Preserve that prevention, native and
browser selection, normal finishing, and exact foreground/desktop restoration.
That result does not cover every session or both installed channels.

The installed Test Intent health history later records a ready session from
2026-10-16 14:29:22 to 14:32:22 UTC ending with `inputTapUnavailable`, after 592
callbacks. It has zero input-tap timeouts, disable events or recovery attempts.
Other sessions before and after finished manually. Installed Test executable UUID
was `B8CB238F-ECC2-39E0-B034-717BA4D4AACC`.

The ready-session producer is the rcmd compatibility invalidation callback. Its
reason was discarded, so the evidence cannot distinguish third-party process,
tap topology, configuration, keyboard-layout, or bounded CLI recheck failures.
This is an observed safety stop, not evidence of a new Intent process crash or
the old callback-timeout failure. The repair adds content-free typed diagnostics
before the existing stop. It does not relax protection or declare this stop fixed.

## Separate browser-helper finding

The system disk-write diagnostic `IntentNativeHost_2026-10-16-220617_Logans-MacBook-Air.diag`
reports 8,590.07 MB dirtied over 16,843 seconds. Its sampled stacks point to
snapshot persistence. The helper UUID matches the installed Test helper.
Repeated correlated outline queries bypass unchanged-inventory suppression and
rewrite multiple full partitions. A failed partition write was also ignored
before advancing cached freshness. Native-side fixes and realistic physical-write
tests have been implemented. No causal link to the safety stop has been established.

The bounded native repair retains the exact profile/request receipt files while
avoiding unchanged base/profile rewrites. Actual geometry still refreshes every
350 ms; unchanged full discovery requests are limited to 1.4-second intervals.
Confirmed inventory expires 2.1 seconds after the oldest profile observation.
Changed ownership, selection or contradictory newer observations invalidate it.
Required failed writes suppress freshness and retry only incomplete destinations;
a newer activation response supersedes an older failed transaction.

Focused Firefox and Chrome fixtures each exercise two profiles and twelve exact
requests per profile: four ordinary inventory writes, 24 receipt writes, with
encoded byte counts checked. Failure fixtures cover profile and receipt writes,
freshness withdrawal, automatic recovery without a new snapshot, and a newer
activation during retry. The activation regression failed on the pre-fix helper
and passed after repair. Independent review also caught and corrected stale
outline acceptance after a newer positive partial observation. Empty placeholders
still do not certify that a selected tab disappeared. Extension JS/version did not
change; asynchronous extension query ordering was not changed by this repair.

The passive rcmd probes total 690 seconds and 612 snapshot updates. They observed
two transient CLI timeouts with stable process/tap identity, followed by recovery;
there was no invalidation. A second instrumented 300-second probe did not reproduce
a timeout. This does not identify the historical stop's cause. Same tap/process
alone cannot attest unchanged rcmd configuration, so the safety bound is retained.

## Hosted installer and website evidence

- All three hosted 202610160004 files already passed byte count, SHA-256,
  signature, Gatekeeper and stapled notarization checks after Firefox download.
- Firefox installed and automatically launched the correct setup preference in
  the previous check; existing user-data hashes were preserved.
- Chrome installation is now confirmed by `/var/log/install.log`: the actual
  Downloads package installed at 2026-10-16 21:19:05 KST and showed Install
  Succeeded at 21:19:06. Its automatic-launch preference was not observed live.
- Both has reached a new protected installation approval; not yet a pass.
- Website source `2cd5e81604f61fe657dbab8622892e0c477d1027` was pushed and version
  19 deployed successfully. The Git push failure was resolved with a child-only
  16 MiB `http.postBuffer` override instead of the global 4096 MiB value. No global
  configuration was changed. The deployment includes the streaming-header
  verification repair and candidate qualification barrier.
- Anonymous checks after deployment: public root 200; missing/invalid invite
  pages and invalid download request 404; unauthenticated owner API 404. Private
  responses carry private/no-store, no-referrer and noindex headers.
- The refreshed owner verifier still needs its browser acceptance check.
- The Chrome Web Store still shows 0.2.14; required 0.2.46 is not publicly approved.

`PINNED_LAUNCH_RELEASE` remains null. Private staging is not a tester release.
Clean-account onboarding, supported OS coverage, exact physical DBT/SBT outlines
and continuity, and full restoration/recovery acceptance remain outstanding.

Evidence: `~/.codex/artifacts/intent-input-isolation-20261016/`. Any new runtime
source requires a fresh frozen gate, installed verification, and freshly signed
packages before its evidence can replace candidate 202610160004.

## Frozen source and local installation

The complete eight-suite change-impact gate passed on 2026-10-16 at 16:42:07 UTC:

```sh
env PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin INTENT_BUILD_JOBS=1 \
  npm run test:changed -- --base 863b08b
```

This includes the final partial-observation and activation-retry repairs, not
only their earlier focused runs. Source fingerprint before and after commits is
`99aa5537616f17c32ccd52ce3cd9697875e817be62b5790722608193cdf7fc52`.
Runtime commits: `c37d74c` (diagnostics), `2a7515e` (native writes/outlines).
Scoped publication branch `codex/input-protection-repair` contains equivalent
commits `5635acb` and `cb75156`. No remote CI pass is claimed.

Both authorized local installations completed with `INTENT_LOCAL_INSTALL_NO_OPEN=1`:

| App | Channel | Installed executable UUID |
| --- | --- | --- |
| `~/Applications/Test Intent.app` | development | `A77890D3-BFDA-38F3-B652-4661D0BEDAA5` |
| `~/Applications/Intent.app` | launch | `DA040978-558A-312E-874C-98E6CEB265FF` |

Each UUID matches its compiled product, `--print-build-channel` returns the
expected channel, and deep strict local signature verification passed. Nine
existing data files were unchanged across the launch installation; that baseline
was taken after Test installation, so it is not a separate before/after Test data
claim. The apps were not launched while the Mac was locked. `/Applications/Intent.app`
remains the signed 202610160004 candidate. No new signed tester package was promoted.

Installed live acceptance, the pending Both installer approval, and refreshed
owner-page verification resume after unlock. Automated passes do not resolve the
later rcmd safety-stop cause or replace physical/clean-account qualification.
