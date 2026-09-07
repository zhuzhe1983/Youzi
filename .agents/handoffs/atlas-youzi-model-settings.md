# Atlas → Pixel / Harbor: unified model settings

Task branch: `atlas/youzi-model-settings`, based on main `8137ae0f`.
Owner Atlas; executing on local Mac. Role files are absent from this checkout.
Main and the separate `atlas/youzi-video-tools` worktree were not edited.

Implemented default / startup / observed-ready separation with one shared list
in Service and scenario tabs, plus quick-picker semantics and backend opt-in
non-replacing admission. See `docs/engineering/decisions/youzi-model-selection-and-startup.md`.

Verified:
- 159 Swift settings/transport/residency/session/tools checks pass.
- 113 Swift audio/image/video/launch-media checks pass.
- 148 Python startup/admission/audio/video/residency checks pass.
- 12 focused Swift checks including isolated Chinese/English 560pt list renders
  pass; PNGs visually inspected, no personal preferences used for that render.
- Ruff and diff whitespace checks pass.

Limitations: one audio cache per lane; process-scoped MTP; video ready is not
permanent weight residency; video native chat tool remains a separate task.
Hardware multi-inference and full interactive settings acceptance are not
claimed by mock tests or synthetic renders.

User explicitly requested local rebuild and restart after completion. Next:
package this branch with its matching runtime, retain the existing app for
rollback, install/restart, verify process/resource loading and service health.
Do not clear preferences, caches or conversations. Do not publish a formal
release or merge main as part of this task without a separate integration step.
