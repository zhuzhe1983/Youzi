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
  Combined candidate packaging is pending.
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
