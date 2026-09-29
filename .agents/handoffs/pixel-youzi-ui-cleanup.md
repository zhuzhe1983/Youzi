# Pixel → Atlas: UI cleanup equivalence and unique scratch recovery

- Owner/host: Pixel, Local Mac. Branch: `pixel/youzi-ui-finish-20260930`.
- Base: `f0ad132c25f322d6babbfe2b5edffc543baab035`.
- Scope: finish the preserved UI patch and audit the original `Youzi-complete`
  scratch bundle without changing either source worktree. Role files were
  unavailable; repository ownership and the workstream contract apply.

## UI result

The original `Youzi-ui-verify` patch is already represented by
`def79da65050a79ac7f0411b358b5abe363b073a`, an ancestor of the base. Both patches
have stable patch-id `840ebd4913adab030648df533000a4d467d14e44`.

Three-way replay was reconciled against the newer localized settings, extracted
model/personalization panels, data-management/security rail, and account-menu
catalog wiring. The replay initially duplicated `arrowEdge`; removing that
duplicate left zero source/test differences. No application code is needed for
this UI completion, and this handoff-only commit does not replace newer work.

Verification: all nine Swift source/test files in the original patch pass
`xcrun swiftc -frontend -parse`; `git diff --check` passes. Native tests were
reserved for Atlas's serialized integration run. Recommended filter:

```sh
cd apps/rapid-mac
swift test --no-parallel --filter 'CustomInstructionsTests|SettingsVisualFoundationTests|YouziAccountMenuTests|SettingsDeepLinkRoutingTests|SettingsEnvironmentInjectionTests'
```

## Scratch result and remaining work

All 66 `.wip-stash` files are unique: 1,173,954 bytes, absent target paths in the
base tree, no equal blob in `git rev-list --objects --all`, and every blob absent
from `git cat-file --batch-check`. This is a non-shallow repository. All 57 Swift
files parse, but parsing does not establish build or runtime compatibility.

The cleanup Butler run's `parallel/workstream-02-scratch-audit.json` and
`parallel/workstream-02-report.md` record every path, SHA-1/SHA-256, size,
declaration, test case and intended change. They distinguish this unique bundle
from the already-merged UI patch. The original bundle and original Butler notes
were read only.

Atlas owns the required recovery decisions:

- Reconcile SQLite Know Me sources and Graph-C UI with the active memory work;
  compose one authority with migration, file ownership and permission boundaries.
- Restore capability/permission/automation/execution work as a coordinated
  feature, including the missing app and chat composition. Domain record presence
  alone does not implement the scheduler or shared runner.
- Reconcile the scratch capability center with the current
  `YouziSimpleHelpersPage` in `YouziSimpleDomainPages.swift`; blindly adding it
  would duplicate that type. Resolve catalog IDs and package registration too.
- Review voice domain/IO/orb behavior against the current live-voice runtime.
  The original voice contract's session controller and tests are absent from
  this bundle, so the bundle is not a complete alternative runtime.

Next action: preserve these files and original implementation notes in an
explicit recovery branch or verified archive before retiring their worktree.
Neither this handoff nor the historical focused-test claims certify them as
merged or delivered. Atlas should run fresh acceptance after any integration.
