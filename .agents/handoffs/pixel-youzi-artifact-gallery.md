# Pixel → Atlas: square deliverable gallery

- Host: Local Mac.
- Branch: `atlas/youzi-artifact-gallery`, based on `24161724` from
  `atlas/youzi-multimodal-tools` because the requested gallery consumes those
  newly generated task artifacts.
- Scope: Pixel UI/media implementation; Atlas receives integration/release work.
  `AGENTS.md` was read; `.agents/roles/` is absent in this checkout, so no role
  file could be read. Work stayed in a separate task worktree.

## Completed and verified

- All artifact kinds use S/M/L square previews with titles and per-card menus.
- Actual image/video thumbnails, direct audio playback, and native media overlay.
- Image fit/physical-pixel 1:1/wheel/pinch/pan, native video controls, Escape and
  backdrop dismissal, and balanced playback/file-scope cleanup.
- File/bookmark ownership remains in the domain layer. Only additive internal
  lease APIs were introduced; no public model API or backend architecture changed.
- Off-main media resolution/decoding, bounded thumbnail cache/overlay decoding,
  late completion guards, unavailable/revoked file handling.
- Scoped regression: 74 tests / 12 suites passed (visual test skipped by default).
- Opt-in native visual journey: 10 tests / 1 suite passed, including real generated
  PNG/WAV/H.264 fixtures, scroll/drag, Escape, video ready-to-display, and close.
- Release configuration compiled successfully (`swift build -c release`); no
  installer was assembled or installed. Existing unrelated compiler warnings remain.
- OS window screenshots inspected for square cards, image overlay, and actual
  video pixels. Captures are temporary, synthetic-only, and not committed.

Commands, resource limits, and rollback are documented in
`docs/engineering/operations/youzi-artifact-gallery.md`.

## Risks / next action for Atlas

1. Integrate this scoped commit after the multimodal-tools base. The user's target
   branch is **main**, not master; no main merge or release is performed here.
2. Release build status is recorded in the completion summary. Do not confuse a
   compiled binary with an installed/signed/notarized client update.
3. Current installed client, active chat, downloads, model residency, and runtime
   override have not been touched or restarted by this gallery task.
4. Earlier TTS failure, message queue work, actual GUI multimodal generation
   acceptance, and upstream-main conflict resolution remain separate tasks.
5. Overlay images larger than the decoding budget are downsampled for safety;
   original bytes and pixel-navigation dimensions remain unchanged. There is no
   claim of unlimited full-resolution/tiled viewing.
6. Package once the pending integration is validated, and coordinate a safe client
   restart rather than interrupting the user's current downloads/chat.
