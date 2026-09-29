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
need an attended run with the required models already serving. Audio/image interpretation tools, same-lane audio
multi-residency, fully incremental ASR and acoustic full-duplex acceptance remain
separate work. HTML storybooks still embed images/audio, not video.


## Installed developer candidate — 2026-09-07

The complete native + Python runtime from clean commit `8b11044e` was built,
backed up, installed and restarted locally as **`candidate-8b11044e`** (marketing
version 0.14.4 / build 174). This is not a new public Release. Whole-bundle strict
signatures, the executable-relative Frameworks rpath, and the installed runtime's
bytecode/import origins passed. Native executable SHA-256:
`b3b77bcb96c0351b1d99bff248d4110965f12978660c8433d70a5091e0220459`.

The offline package smoke is now repeatable without a checkout Python, weights,
production endpoint, user approval action, microphone or speaker:

```sh
runtime="/Applications/Rapid-MLX Desktop.app/Contents/Resources/rapid-mlx"
probe="$PWD/apps/rapid-mac/scripts/verify-youzi-model-bundle.py"
env -i PATH=/usr/bin:/bin HOME="$HOME" \
  PYTHONPATH="$runtime/site-packages" PYTHONNOUSERSITE=1 \
  PYTHONDONTWRITEBYTECODE=1 HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
  RAPID_DESKTOP_NO_PORT_SWEEP=1 \
  "$runtime/python/bin/python3" -P -B "$probe" "$runtime/site-packages"
```

The probe asserts ten module origins inside the sourceless runtime, five
text-route selection boundaries, authenticated live policy, explicit video
capabilities beside primary chat, and synthetic LTX POST/GET/content identity.
It also proves that queued-only cancellation of an already-completed video
returns 409 without deleting its content. Synthetic MP4 bytes only exercise
transport; they are not a playable video or evidence of actual generation.

The old complete `candidate-a6bb13f8` was backed up and its file/symlink manifest
compared before normal UI quit. Both its verified copy and untouched original
are retained under the local Youzi Client Backups directory, in
`0.14.4-before-chat-video-tools-20260907-214606`. Rollback requires a normal quit
and restoring the **whole original application**, followed by strict signature
verification and launch with the no-port-sweep flag. Do not patch signed contents,
reset preferences or overwrite task/model files.

Seven post-launch samples over 60.411 seconds retained the same app process,
with no new Rapid crash report. The package's own Python child appeared during
that observation; a subsequent read-only check returned `/health` 200/ready.
Discovery then advertised resident image, video, STT and TTS models, but no chat
model. Exact Wan video capabilities also returned 200 with its canonical model
identity. These checks did not generate media or initiate model loading.

The native UI was accessible, and user interaction was detected during read-only
acceptance. UI actions were stopped rather than overriding the user's activity.
The live-voice sheet showed microphone off and missing-model guidance. A missing
chat model prevents conversational/voice acceptance; it is not another observed
audio callback crash. Physical AEC/double-talk, actual model-generated video and
LLM tool choice remain unverified. The inherited `audio_lanes` discovery-test
failure documented in the model-policy handoff remains outside this change.
