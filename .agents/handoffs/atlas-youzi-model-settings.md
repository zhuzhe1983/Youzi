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

## Local delivery completed — 2026-09-07

Built and installed `candidate-d56811c2` (base version 0.14.4) with a fresh
matching bundled runtime via `apps/rapid-mac/scripts/build.sh`. Deep strict
codesign verification and bundled CLI version/help passed. Kept the previous
app under `~/Library/Application Support/Youzi/Client Backups/` before replacing
the installed bundle. No preferences, tasks or model caches were cleared.

Launched the installed app with `RAPID_DESKTOP_NO_PORT_SWEEP=1`; native AX
inspection confirmed the main window, existing tasks, ready chat model and
settings window. The user then changed the foreground window, so no further
interactive settings changes were made. Full UI behavior acceptance remains
with Pixel/user; the isolated shared-list renders are the detailed visual check.

Runtime checks on the installed app: `/health` and `/health/ready` returned200
and ready, `/v1/models` returned200 with the actual chat model, and a real
`/v1/responses` request completed200 with output `OK`. Unauthenticated admin
residency access correctly returned401. Importing the installed bundled schema
confirmed the new strict preservation flag. No real same-type multi-model
inference test or audio-cache expansion is claimed.

Branch pushed to origin. Main integration and formal release are not performed
by this task; installed candidate identity remains d56811c2 even though this
handoff-only commit follows it.
