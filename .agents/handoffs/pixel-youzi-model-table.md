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
  The additional native horizontal-scroll/header-alignment selection passed
  (31 tests / 3 suites).
- Rendering is fixture-only. It must not be reported as an actual model download,
  model inference benchmark, microphone, speaker or full-duplex acceptance.
- Every native build/test/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`.

- Paired Release app `candidate-2a0de777` built with a fresh bundled Python
  sidecar; deep/strict signature and resource checks passed. A controlled idle
  restart launched this worktree candidate, and its own backend became healthy
  with the selected chat model. Installed bundle and rollback candidate untouched.
- Follow-up removes the scenario title and labels remaining RAM as
  `可用内存：80.0G` / `Available memory: 80.0G`; refresh shares the memory row.
  39 tests / 9 suites passed, including Chinese/English window-capture fixtures.
  This follow-up is source-verified, not yet packaged into the running app.

## Remaining integration actions / risks

- Receiver: Atlas / next UI delivery owner. Review and integrate this scoped branch.
- The worktree build bundle is currently running. Do not rerun its packaging
  script (which removes/recreates that bundle); use a new task worktree/output.
- Preserve the running healthy local candidate until a replacement is ready;
  don't interrupt user chats. No actual model/voice acceptance claimed here.
- Main integration and any release remain separate, explicitly authorized work.
