# Browser onboarding handoff

Reported flow: a tester chooses Firefox, Chrome or Both on the private download
page, installs Intent, and should land in setup with that choice retained. Each
selected profile must have the permanent matching extension and a fresh reply
from that exact profile before setup says connected. Opening an install page or
another profile's heartbeat must never count as success.

Adjacent invariants: existing onboarding completion and profile choices survive
updates; launch/Test preferences remain isolated; browser profiles and user tabs
are not modified or closed; permission handoffs stay resumable; actual B mode,
Caps Lock + backtick and saved-slot flows remain owned by existing handlers.

Implementation and deterministic evidence will be recorded below. GUI/profile
acceptance and installer handoff remain pending until exercised by the main task.

## Implemented

- Fresh setup accepts one validated `--setup-browsers=firefox|chrome|both` value.
  With no explicit choice, launch Intent can recover the same choice from the
  installer's root-owned, non-writable, bounded receipt at
  `/Library/Application Support/Intent/onboarding-browser-choice.json`, only
  when its build matches the installed app. Test ignores that receipt. Existing
  progress, selections, bindings and legacy completion are never replaced.
- Selected local profiles persist separately from connection state. Installation
  metadata is displayed separately from live connection. Automatic refresh uses
  a correlated snapshot from each durable browser profile, exact runtime Guard
  version and required capabilities. Another profile's aggregate heartbeat or
  having opened an installation page cannot mark a profile connected.
- A first binding requires an explicit, time-limited confirmation on a unique
  local browser page plus a fresh correlated inventory containing that page.
  Firefox also checks the local profile's process owner. Chrome confirmation is
  the user's confirmation of the visible browser profile, not an independently
  verified mapping to a filesystem directory. Moving/duplicating a verification
  tab across profiles is not treated as directory proof. Ambiguous replies stay
  pending. Selection/settings changes invalidate pending snapshot work.
- New onboarding begins Welcome → Permissions → Browsers → First intention.
  Existing interrupted optional-name screens still resume. Names remain optional;
  B mode, Recent intentions bookmarks and numbered saved slots replace the old
  canvas/reselect/finish-and-save teaching. The guide does not end an active
  intention to save it.

## Deterministic checks prepared

Browser-profile fixtures cover three installer choices, malformed/duplicate
arguments, receipt build/schema validation, delayed first launch, update/resume
preservation, profile deletion, confirmation nonce/channel/expiry and connection
freshness. Core cases cover unnamed onboarding, preserved legacy name-step
resumption, old snapshot decoding without fabricated version, disabled/missing
capabilities and old runtime Guard versions. Native-host tests cover exact
per-profile version separation and correlated discovery replies.

Executed here: Swift frontend parsing of changed app/core/spec files, Node syntax
checks for both modified native-host suites, and `git diff --check` passed.
No Swift builds, installed-app checks, GUI actions or publication were performed
by this agent; the parent owns serial compiled and live acceptance. A successful
build or source test must not be described as installed-profile acceptance.

## Remaining acceptance

Run the compiled profile/core/native suites and app build. Exercise fresh guest
onboarding, denied/granted/revoked permissions, restart at each setup stage,
Chrome wrong-profile confirmation, Firefox already-running named profiles,
stale/disabled/outdated Guard, multiple profiles, and live disconnect. Confirm
installer auto-launch and delayed manual launch retain the website choice.
Firefox cannot reliably forward an external URL into an already-running named
profile; that case copies the setup URL and requires the user to paste it into
that profile. Browser installation approval and macOS permissions remain native
user actions.

## Review corrections and focused verification

Read-only review found that transient discovery failures could drop persisted
selected profiles, and Both could finish after discovering only Firefox. Those
paths now retain every selected ID, show missing profiles as pending/removable,
show requested missing browsers separately, and require an explicit browser
choice change before completion. Closing unchanged setup preserves completion.
Known-profile replies publish immediately; unrelated owner queries are omitted
unless a new binding needs ambiguity checks. A silent-owner wait ends before the
next two-second refresh, keeping the three-second liveness receipt current.
Firefox process ownership and duplicate binding rejection apply to existing as
well as new bindings.

Executed after these corrections: `bash scripts/test-browser-profile-setup.sh`
passed, including delayed install handoff, missing Both browser, transient
metadata failure, missing selected profile and explicit removal cases. Shared
core/native/app gates remain owned by the parent; source-fixture success is not
live browser acceptance.

Final transition review added a symmetric Chrome/Firefox regression: when Both
was chosen and one browser appears only after initial selection was persisted,
that browser remains pending until profiles are selected and connected or the
user explicitly chooses Continue without it. An available-but-unselected
requested browser now offers Select profiles beside the explicit reduction.
Readiness also requires every selected ID to be present in current discovery,
so a recent connection receipt cannot certify missing metadata. The compiled
browser-profile suite passed after these transition tests.
