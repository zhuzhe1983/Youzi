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

Next: after the user unlocks the desktop, finish native interaction acceptance
and switch clients with normal Quit; packaging results are recorded below.
Risk: nested scrolling and pinned Section behavior need native acceptance beyond
layout-math tests. Preserve the prior running app as rollback, use normal Quit,
and set `RAPID_DESKTOP_NO_PORT_SWEEP=1` for build/test/launch. Do not replace a
running sibling's bundle or change downloaded models/auth settings.

## Local candidate verification

Code commit: `4772994a`; candidate identity: `candidate-4772994a`.
Full Release app with rebuilt bundled sidecar completed successfully (engine
`rapid-mlx 0.14.4`). `codesign --verify --deep --strict` and
`verify-app-resources.swift` pass, including template JSON, compiled Chinese
localization, logo, math fonts and Mermaid digest. No inference smoke requested
or performed for this UI-only task; no claim of a fresh multimodal end-to-end run.

App: task worktree `apps/rapid-mac/build/Rapid-MLX Desktop.app`.
Code and verification notes are pushed to the task branch, not merged into main.

Native acceptance / restart remains pending: macOS reports
`CGSSessionScreenIsLocked=Yes`; CUA cannot acquire the app window
(`cgWindowNotFound`). Do not bypass the lock or force-terminate the old client.
The previous `Youzi-image-tool-failure` worktree client is still running and its
complete app bundle is untouched. The new candidate has **not** been launched.
Synthetic layout screenshots verify five-row default/three-row short viewports,
expansion flow and fixed footer, but are not a substitute for actual click/scroll
acceptance. Next owner: Pixel; after unlock, verify idle/draft state, normal Quit,
launch this exact candidate with `RAPID_DESKTOP_NO_PORT_SWEEP=1`, then check the
More routes, search/filter, inner scroll, expanded sticky header and collapse.
