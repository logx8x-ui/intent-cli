# Source publication without expanding GitHub access

The user could not complete phone verification while sleeping and authorized
safe alternatives. The existing credential already permits ordinary repository
writes but cannot change workflow files. No credential, phone number, two-factor
setting, or security scope was changed.

## Published source

- Existing main working branch remains `codex/name-first-intentions` at
  `b3fec3e`, with the pending workflow-only commit `65f5629` preserved beneath it.
- A separate managed worktree started from remote branch tip `9b16cca`.
  Cherry-picking only the feature/fix commit created `a8ef75d` on
  `codex/overview-finder-fixes`.
- `git diff --name-status b3fec3e a8ef75d` showed exactly one difference:
  `.github/workflows/beta-updates.yml`. Source, extensions, tests, package files,
  and existing QA evidence are identical to the installed/tested candidate.
- `git diff --exit-code 9b16cca a8ef75d -- .github/workflows` passed: no workflow
  changes are published by the new branch.
- Ordinary non-force push succeeded. `git ls-remote` independently confirmed
  `a8ef75d39cfe29500d7c3b01628adca9dca7c7af` on the new remote branch.

No main-branch merge, release tag, updater-feed change, or browser-store submission
was performed. The existing remote workflow only publishes on main, so this
source branch does not distribute an unaccepted tester build. The pending CI gate
improvement, matching permanent signed Firefox release, and physical acceptance
boundaries from the October 5 QA note remain outstanding. The extra commit
containing this note is documentation-only; automated/live results are those of
the source-identical candidate, not a newly rerun suite.
