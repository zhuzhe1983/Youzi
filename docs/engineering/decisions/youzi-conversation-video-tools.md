# Conversation video tools

2026-09-07. Owner: integration, local Mac. Scope: native function-tool video
workflow, shared by Simple and Professional chat. Depends on the unified ordered
automatic model pool and selected-video co-residency changes. The assigned role
files and Orca tooling are absent; work uses a separate standard Git worktree.
Main, user preferences, downloaded weights and existing conversations stay intact.

## Contract

- `youzi_models` advertises video generation only for catalog video entries with
  supported modes. `youzi_video_capabilities` is read-only: stopped models return
  not-ready; it does not approve/start/download them.
- `youzi_generate_video` accepts prompt, optional exact model, supported size and
  seconds presets, and optionally an image artifact UUID from the same task.
  No URLs, local paths, credentials or model-supplied approval flags are accepted.
- Omitted model resolves the automatic video pool, ready-first; an explicit model
  stays exact. The existing approval path admits downloaded cold models without
  replacing the primary chat or changing automatic membership. Denial is not
  retried within a user turn. Nothing downloads weights.
- The runner queries capabilities for the selected alias. Omitted size/duration
  reuse compatible Settings defaults; explicitly unsupported controls fail before
  POST instead of silently falling back. Reference MIME/pixel/byte limits are
  checked from image metadata, not a model-supplied filename.
- Every network stage is bound to a captured server session epoch, port and key.
  Restarts with the same key/port still invalidate the call. Keys never appear in
  tool schemas/results. A separate ephemeral transport refuses redirects and uses
  finite request/resource timeouts.
- Only the job ID returned by this call's validated POST may be polled, fetched or
  canceled. No history listing, arbitrary job ID parameter, stale preview-cache
  reuse or automatic resubmission. POST and GET preserve the resolved model name,
  including explicit HF identities for LTX 2.3.
- Waiting is limited to 300 polls / 10 minutes plus bounded in-flight network and
  cleanup operations. Downloaded content is limited to 64 MiB, including chunked
  responses, with an MP4 MIME/container sanity check. This is not full media
  decoding validation.
- Only successful, uncanceled output becomes a `.video` artifact in My Files,
  attached to the originally captured task. Switching the selected chat cannot
  redirect the file to another task. Completed server jobs are retained for the
  Video workspace, even when content retrieval fails.

## Stop and failure semantics

Stop cancels waiting and attempts DELETE on this call's pending job only, and only
while the captured session is still current. A queued job can be canceled. Cleanup uses `DELETE ?pending_only=true`, checked
under the server job-state lock: a job that completed after the last poll is
preserved, not deleted by stale cleanup. Ordinary workspace deletion retains its
existing behavior. The
existing backend rejects deletion of in-progress GPU work with HTTP 409: it can
continue in Videos, and neither the UI nor skill promises immediate GPU abortion.
No model unload, chat restart or whole-service cancellation is attempted.

If POST loses its response, the tool does not know a safe owned ID; it does not
list/delete guessed jobs or resubmit. Report failure and inspect Videos. If the
session changes, cleanup never targets the replacement session. No raw backend
error, private path or key is echoed to the LLM.

## Verification / acceptance

Use `RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac -c
release --filter 'YouziLocalModelToolsTests|YouziLocalVideoToolTests|VideoClientTests|VideoGenViewModelTests'`
for native policy, dispatch, captured task ownership, approval/denial, exact
capabilities, presets, reference scope, session changes, bounded polling/content,
cancellation and schema regression. Python tests cover exact POST/GET identities
alongside the LTX/Wan/CogVideo capabilities/residency/job-persistence suites.

The expanded native regression passed **380 tests / 46 suites**, including
model policy, startup, settings, live audio callbacks and video workspaces. The
eight Python video/policy suites passed **218 tests**. AST parsing and
`git diff --check` passed. These are synthetic protocol/lifecycle tests, not real model inference. Actual
LLM tool selection, video decoding/playback, generation latency and GUI consent
need an unlocked attended run. Audio/image interpretation tools, same-lane audio
multi-residency, fully incremental ASR and acoustic full-duplex acceptance remain
separate work. HTML storybooks still embed images/audio, not video.
