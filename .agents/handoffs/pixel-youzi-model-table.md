# Pixel → integration: model files table and scenario toolbar

- Owner/host: Pixel, local Mac.
- Branch: `pixel/youzi-model-table`.
- Base: `b8e16ca7` from `youzi/live-voice-stall`, explicitly retaining the locally
  delivered voice fixes. The separate main checkout is untouched.
- Scope: native model table, presentation metrics, UI routing and regression QA.
  No backend/public API or automatic-loading policy change.
- Role files and Orca were unavailable in this checkout; a dedicated Git worktree
  was used. No delegation, release, main merge or installed-bundle replacement.

## Implementation

- Shared NSTableView across model-file categories: sortable/resizable/reorderable
  columns, search + intersecting filters, existing hardware top-two picks, guarded
  download/load/delete, status/progress, and explicit missing/estimated metrics.
- BenchScores only adds optional decoding of the already-recorded `speed_source`.
  No benchmark numbers or recommendation registry changed.
- Scenario popup removes the explanatory paragraph and places the settings link
  to the right of the segmented tabs; keeps per-scenario settings routing.
- Obsolete private card/list views removed. Legacy pure geometry helpers remain
  because other regression and DevSnapshot consumers still reference them.
- Product semantics and reproducible checks: `docs/guides/youzi-model-files-table.md`.

## Verification checkpoint

- Initial Release compilation passed.
- Final targeted selection: 144 tests in 8 suites passed, including fixture
  rendering, real native-header sort callbacks, and both languages × four font
  sizes for the scenario toolbar. Window captures confirm text/control visibility.
  An additional native horizontal-scroll/header-alignment check is in progress.
- Rendering is fixture-only. It must not be reported as an actual model download,
  model inference benchmark, microphone, speaker or full-duplex acceptance.
- Every native build/test/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`.

## Remaining integration actions / risks

- Review final window captures, especially English/large-font scenario toolbar
  and horizontal access to table metrics. Review final Release results.
- Build a full paired native+sidecar candidate and verify bundle identity/signature;
  do not patch the older installed bundle or select an old runtime override.
- Preserve the running healthy local candidate until the replacement is ready.
- Main integration and any release remain separate, explicitly authorized work.
