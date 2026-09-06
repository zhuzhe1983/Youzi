# Atlas → Atlas / Pixel / Harbor: Youzi resident services

- Date: 2026-09-06; owner Atlas on Local Mac. `AGENTS.md` read; role files are
  absent. Dedicated worktree/branch `atlas/youzi-multimodel`, based on local
  delivery `c32379fe`. No main/upstream merge and no user-data migration.
- Scope: actual shared audio preload, correct audio discovery, media co-loading
  without chat performance overrides or primary process restart, explicit
  downloaded-only resident selectors and startup restore. Images selected while
  resident mode is enabled are pinned. Existing API-key policy remains intact.
- UI: Settings → Models → Model service; three media selectors alongside current
  chat status; explicit load, loading/ready/busy/errors. Audio memory bytes remain
  unknown rather than the old synthetic 1 byte. Video dynamic residency excluded.
- Regression evidence: 47 Swift tests / four suites passed; 177 Python tests passed,
  four skipped. Ruff and `git diff --check` passed. Final release executable build
  succeeded (89.69s on this host); pre-existing warnings remain. This timing is
  compilation evidence, not an inference benchmark.
- Real isolated runtime: Qwen 27B + Qwen3-TTS 4-bit + Whisper large-v3-turbo +
  Z-Image-Turbo simultaneously resident and all four inference paths succeeded;
  `evictions_total=0`. OpenAI SDK model listing, ordinary Responses and streaming
  Responses succeeded. Missing Whisper Small processor assets were detected and
  rejected at preload without removing chat/image/TTS. See the operation doc for
  exact environment and reproducible checks.
- Isolation: real testing used a verified cloned installed runtime on a separate
  loopback port, offline, without downloading weights. The user's active client
  and runtime override were not replaced or restarted during development/testing.
  Source Swift compilation alone does not update the installed Python runtime.

## Delivery state

- Implementation commit `37e75526` pushed to `atlas/youzi-multimodel` and safely
  fast-forwarded into `atlas/youzi-local-delivery` after confirming local/remote
  delivery were still `c32379fe` and had no tracked edits. Main was untouched;
  the delivery worktree's existing untracked scratch directories were preserved.
- A complete local candidate was assembled under the task worktree at
  `apps/rapid-mac/build/Rapid-MLX Desktop.app`, identity `candidate-37e75526`.
  Its bundled runtime is the verified offline-tested clone with the changed
  modules, not a fresh dependency rebuild. Deep/strict ad-hoc signature
  verification passed. This is not Apple notarization or public publication.
- The candidate has not replaced/restarted the user's running app. The old
  active runtime override takes precedence when opening apps normally; install
  the matching override safely, or launch the candidate explicitly with
  `RAPID_BIN` pointing to its bundled `Contents/Resources/rapid-mlx/bin/rapid-mlx`
  after quitting the old client. Do not imply double-clicking an arbitrary
  candidate will update the active override.
- User service on its original port returned HTTP 200/healthy after all tests.
  The exact owned isolated inference process was sent SIGTERM after validation
  to return the duplicate model memory; no broad process/port sweep was used.

## Limits and next actions

- Receiver Atlas: deliver a complete candidate app plus matching runtime, not an
  executable-only replacement. Back up the full installed app/runtime before any
  restart; check the active override precedence and re-sign. Do not call this a
  published release. The previous stable-release updater and public release work
  remain separate and are not completed by this branch.
- Receiver Pixel: native visual/interaction QA of the new settings, especially
  extra-large font and compact widths, remains distinct from compilation/unit
  tests. Configuration changes persist but load only on explicit action/startup;
  disabling restore does not unload current models.
- Receiver Harbor: public packaging/notarization and clean-room runtime rebuild
  remain unverified. This local runtime was cloned and patched after baseline
  code-object checks. Follow `docs/engineering/operations/youzi-delivery.md`.
- Audio admission is a preflight estimate, not an atomic cross-lane reservation.
  Same-lane audio replacement can lose the outgoing engine on load failure. Other
  lanes are preserved; unrestricted GPU concurrency and arbitrary checkpoints
  are not promised. Existing default aliases do not follow the resident selector:
  API clients should send the explicit selected model ID.
