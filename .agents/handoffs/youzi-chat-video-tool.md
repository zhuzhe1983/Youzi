# Conversation video tools — integration handoff

Updated: 2026-09-07. Owner: integration (Atlas), local Mac. Receiving role:
Pixel for attended GUI acceptance; Harbor for eventual release integration.
Branch: `youzi/chat-video-tool`, based on `148e264f` from the preferred-model-pool
branch. Assigned role files and Orca are absent; standard isolated task worktree
used. Primary `main` and its three local commits are unchanged. No public release
or main merge is authorized by this task.

## Scope and contract

See `docs/engineering/decisions/youzi-conversation-video-tools.md`.
Native tools shared by both chat modes add video capabilities and text/image to
video generation. Omitted model uses the automatic pool; explicit requests stay
exact; cold models need the existing human startup approval. No downloading,
enrollment, primary-chat replacement or model unload. Reference images must be
artifacts owned by the captured task. Output is a bounded MP4 artifact in that
same task, independent of later chat selection. Only a validated POST-owned job
may be polled/downloaded/canceled. Captured session epoch invalidates same-key,
same-port restarts. Transport rejects redirects and has finite timeouts.

Backend LTX 2.3 now retains the resolved request alias/HF identity in POST/GET
jobs, matching other video families. Queued-only job cancellation is attempted on
Stop/timeout; an atomic `pending_only=true` guard preserves already-completed
results. Running GPU work returns 409 and can continue in Videos. Unknown
POST outcomes are not retried, listed or guessed for cleanup.

## Verification checkpoint

- Python video/residency/policy suites: 218 tests passed, synthetic engines only.
- Native release regression: **380 tests / 46 suites passed**, including video
  transport, tool registry, cancellation, callbacks, policy, settings and startup.
- Clean source `8b11044e` was committed/pushed, fully built with a fresh sidecar,
  installed as `candidate-8b11044e`, and restarted. No SKIP_SIDECAR/in-place patch.
- Strict signature/rpath checks and full staged/backup file+symlink manifest
  comparisons passed. Native SHA-256:
  `b3b77bcb96c0351b1d99bff248d4110965f12978660c8433d70a5091e0220459`.
- The offline probe `apps/rapid-mac/scripts/verify-youzi-model-bundle.py` passed
  against the installed sourceless runtime: ten imports, five text-route selection
  boundaries, auth/live policy, exact video, synthetic job content and preservation
  of completed output during queued-only cancellation. No real weights/inference.
- Seven samples over 60.411s retained the same app process, no new Rapid report.
  Its bundled Python child subsequently answered `/health` 200/ready and advertised
  image/video/STT/TTS, but no loaded chat. Exact Wan capabilities returned 200.
  Agent verification did not initiate these loads or change startup preferences.
- Every native test/build/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
  Use isolated test preferences. Do not clear user caches/tasks/permissions or
  implicitly start models/microphone to manufacture acceptance.

## Delivery / rollback

Current installed bundle: `candidate-8b11044e`, version 0.14.4/build174. Both the
verified previous copy and untouched `candidate-a6bb13f8` original are retained
under `~/Library/Application Support/Youzi/Client Backups/` in
`0.14.4-before-chat-video-tools-20260907-214606`. Restore the whole original only
after normal quit and checking for active work; verify strict/deep signatures.
No user state, permissions, keychain, model weights or runtime override was reset.

Source and regression evidence: commit `8b11044e`. Delivery verification script
and documentation were added afterward; no product runtime changes followed that
clean build. This does not require rebuilding the same native/sidecar candidate.
At the time of that delivery, main remained at `8137ae0f`; later integration is recorded separately.

## Risks and next concrete actions

1. Pixel/integration: attended LLM-selected video tool call with an already-loaded
   chat model, startup consent presentation, real MP4 generation/decoding/playback,
   task ownership and Stop behavior. The user was active in the native client;
   do not repeat an outdated locked-screen claim or interfere with their session.
2. Integration/voice: implement the remaining near-end/echo-aware barge-in and
   half-duplex playback-tail state, separately from this video-tool branch. See
   `youzi-full-duplex-assessment.md`. Acoustic double-talk/latency acceptance needs
   explicit live microphone use; offline callback/HTTP tests do not establish it.
3. Follow-up scopes: fully incremental ASR, audio/image interpretation tools and
   multiple resident models within a single audio lane remain open. Keep those
   architecture changes separate. Current storybooks embed image/audio only.
4. Harbor: review the task branch and integration history; public release/main
   integration still needs explicit human authorization. Keep rollback bundles.

The prior inherited audio-lanes discovery test failure remains documented in the
model-policy handoff; 218 targeted Python passes are not a whole-backend pass.

## Integration follow-up — 2026-09-30

The user authorized main integration and completed-worktree cleanup. The original
video-tool diagnostics and offline probe are included in the current integration
candidate. The probe reran successfully against the installed sourceless runtime
with synthetic engines and temporary video files. No inference, model load or
application replacement occurred. Historical delivery claims above remain dated.
