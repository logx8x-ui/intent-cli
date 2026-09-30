# Native Apple Spotlight in Intent's overview

Supersedes the custom overview app picker in d0c2eee. That picker was not the
requested Apple Spotlight workflow and has been removed.

## Behavior

- Command–Space and the “Apple Spotlight · ⌘Space” button open the actual system
  Spotlight panel above Intent's overview. An Intent-owned search field is not
  used.
- Inside the overview, Return submits the selected application result without a
  backtick marker. Outside the overview, one leading or trailing backtick still
  explicitly marks a Spotlight app search for the staged-selection workflow.
- Application identification uses the selected result's application URL, or an
  exact, unique installed-app label in an application-provider result. It never
  infers an application from a fuzzy query, bookmark, document or ambiguous name.
- macOS Tahoe's actual AX result cells identify applications using
  `Bundle:com.apple.applications`. The earlier URL-only assumption missed these.
- The global keyboard tap lowers the overview before macOS processes the opening
  shortcut; relying only on an AppKit local key monitor was too late.
- No AX traversal runs in the input tap. Search/result work runs on a separate
  queue with bounded messaging/traversal deadlines.
- The selected app is recorded in the existing name-first flow and rendered with
  its real icon. Allow selections retain background preparation; block selections
  do not launch the app. Persistent app presets remain outside the grid.
- Escape exits immediately even while editing; backtick alone exits on release;
  backtick–Escape clears and exits. Held-prefix modifier numbers continue to work.
- Closing invalidates pending Spotlight submissions before removing the panel;
  the main-queue delivery checks that revision again.

## Verification

- IntentCoreSpec passed, including 100 overview gesture sequences, real Tahoe
  application-cell metadata, exact selected labels, ambiguous labels, bookmarks,
  partial queries, held modifier controls, and marked/unmarked query policies.
- Release IntentApp build passed using the compatibility linker (`-ld_classic`).
- Development installer completed and relaunched the stable user bundle.
- Source/installed IntentApp UUIDs matched:
  B590C6EA-B0B5-372F-A8AC-84F829EEF33B. Strict/deep code-sign verification passed.
- Live CUA observation confirmed the actual Spotlight system dialog opens from
  Intent's button, accepts Calculator, and shows the selected native application
  cell. The removed custom picker is absent. Finder remains only in presets.

## Acceptance still outstanding

The automation's app-targeted key delivery did not establish acceptance of the
system/global Return interception. A physical Return check is requested with a
real Calculator result prepared. Physical Command–Space, repeated Escape and
backtick–Escape, arrow-selected alternatives, unopened-app background preparation,
and block-mode selection still require direct acceptance. These are not counted
as passing merely because compilation or pure tests pass.

The installer separately reports an outdated permanent Firefox Browser Guard.
This change does not modify browser rules or claim that store/profile release
acceptance is complete.
