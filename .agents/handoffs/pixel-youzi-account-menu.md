# Pixel → Atlas: compact shared account menu

- Owner/host: Pixel, local Mac. Branch: `pixel/youzi-account-menu`.
- Base: `aeeb6a93` (`pixel/youzi-model-table`), deliberately retaining the local
  table, memory-header and earlier live-voice fixes. Main checkout untouched.
- Role files / Orca were unavailable; dedicated Git worktree used, no delegation.
- Scope: shared profile entry, top-right native Simple/Pro picker, local labels,
  runtime-free UI seams and regression fixtures. No APIs, backend, model loading,
  user data migration or update/release policy changes.
- Removed only the requested dropdown content. Settings, theme, status and update
  checking keep their existing application services.
- Verification: Release build and 15 tests / 4 suites passed. Native segmented
  control actions exercised both directions with isolated persistence, across
  Chinese/English × all four font sizes × both initial modes. Sixteen native
  window captures; Chinese medium/dark and English extra-large/light reviewed.
  Settings/update test callbacks remained untouched. No live-user settings changed.
- Local bundle delivery is pending the preceding Markdown table screenshot fix;
  compilation/fixture success is not claimed as a live client restart.
- Receiving role: Atlas / next integration owner. Integrate this branch only after
  reviewing UI evidence; a release and main merge require separate authorization.
- Active user candidate belongs to the preceding model-table worktree. Do not
  overwrite its running app bundle, interrupt active chats, or run a port sweep.
- Documentation/reproducible checks: `docs/guides/youzi-account-menu.md`.
