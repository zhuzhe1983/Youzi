# Pixel → Atlas: chat table fill and combined local UI candidate

- Owner/host: Pixel, local Mac. Branch: `pixel/youzi-markdown-table-fill`.
- Base: `b2dd0a67` from `pixel/youzi-account-menu`, retaining the already-verified
  account menu, model table, memory header and local voice fixes.
- Dedicated Git worktree; role files and Orca unavailable, no delegation.
- Production diff: one column-filling frame in the active native table renderer.
  No Markdown parser, HTML, public API, model service or settings changes.

## Evidence

- Standalone native before/after probe extracted the production table view
  verbatim (minimal data stubs only): diagnostic header coverage 47.2% → 100%;
  complete horizontal edges 2 → 5, vertical edges 2 → 4 for a 4-row/3-column table.
  It reproduced the screenshot's partial fill and divider behavior.
- First full Release run: 83 of 84 selected tests passed. The new pixel assertion
  initially assumed raw RGB values; native display-profile conversion invalidated
  that assumption. Detector corrected to channel dominance; product fix unchanged.
- Final Release verification: 84 tests / 17 suites passed, including the tall
  diagnostic fixture, both native mode-switch directions and model picker
  rendering. Light/extra-large and dark/narrow table captures were reviewed.
  Combined candidate delivery is recorded below.
- Reproducible fixtures and behavior: `docs/guides/youzi-markdown-tables.md`.
- Do not copy SwiftPM ModuleCache directories across worktree paths: embedded
  absolute paths cause precompiled-module failures. Fresh per-worktree native
  build outputs were used after quarantining the copied generated cache.

## Delivery / remaining integration

- Receiver: Atlas / integration owner. Review the scoped commits; main checkout
  remains unchanged. No main merge, release or installed-bundle replacement.
- Account-menu and model-table branches are pushed to origin.
- Keep the old healthy candidate until a complete, verified replacement is ready.
  Every build/test/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`; never port-sweep,
  change runtime overrides or interrupt a running user chat.

## Local delivery — 2026-09-08

- Full paired Release bundle `candidate-a72a8115` built in this worktree at
  `apps/rapid-mac/build/Rapid-MLX Desktop.app`, with a freshly built Python
  sidecar (no `SKIP_SIDECAR`). Version/build remain 0.14.4 / 174.
- Deep/strict signature verification, packaged resource verifier (including
  Chinese strings, math fonts and Mermaid digest), and bundled CLI `--version`
  all passed. No source edits were made during compilation.
- Prior `candidate-2a0de777` reported healthy and zero running/waiting chat
  requests over three samples. Normal GUI Quit closed both its native process
  and owned backend; port 8000 was free before launching the new exact bundle
  with `open --env RAPID_DESKTOP_NO_PORT_SWEEP=1`.
- New client visibly shows the inline mode tag and compact menu, without the
  removed subtitle/switch/help rows. A live Simple → Professional switch worked.
  The user then took over and returned to Simple / Workspaces. Further GUI
  actions stopped rather than overriding their interaction. Both directions
  were already covered by the native control regression suite.
- Important runtime boundary: the new native client is running, but no owned
  model-server child or port-8000 listener was present at the final read-only
  check. This is not a claim of server readiness or full inference acceptance.
  The old model service stopped with normal Quit; no startup preferences were
  changed and no model was manually started while the user used the interface.
  The user was notified of this state. Next step, if requested: start their
  selected model through the normal client control and verify `/health`.
- All three task branches are pushed. This handoff-only follow-up does not alter
  the compiled source identity. Main and the installed application stay intact.
- Rollback remains the unchanged sibling `Youzi-model-table` candidate bundle;
  only switch back after checking active work. No release or main merge done.
