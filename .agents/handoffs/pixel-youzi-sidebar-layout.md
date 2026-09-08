# Pixel -> Atlas / Harbor: Simple sidebar layout

Branch: `pixel/youzi-sidebar-layout` (local Mac), based on `b3de8e03` from
`pixel/youzi-image-tool-failure`; includes that branch's preceding fixes.
The configured `.agents/roles/` files and Orca command are absent in this checkout;
a separate Git worktree is used. No main integration/release is authorized here.

Implemented: centered welcome/composer; four primary shortcuts without duplicate
Workspaces; fixed collection headers with More and Expand/Collapse; adaptive
at-most-five-row scroll viewports; expansion pushes subsequent sections without
moving footer; searchable/filterable complete Tasks page using canonical records.
Public APIs, task storage, inference, and prior inline-media behavior unchanged.

Verified before app packaging: 27 scoped Swift tests / seven suites pass; synthetic
short/tall/expanded/English rendering. See
`docs/engineering/operations/youzi-sidebar-layout.md` for commands and constraints.
Corrected a pre-existing source-order test assumption, not production submission.

Next: complete full native+sidecar Release packaging, signature/resource checks,
and native interaction acceptance; record exact candidate and results below.
Risk: nested scrolling and pinned Section behavior need native acceptance beyond
layout-math tests. Preserve the prior running app as rollback, use normal Quit,
and set `RAPID_DESKTOP_NO_PORT_SWEEP=1` for build/test/launch. Do not replace a
running sibling's bundle or change downloaded models/auth settings.
