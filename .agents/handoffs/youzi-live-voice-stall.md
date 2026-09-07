# Live voice stall — candidate mitigation, not attended acceptance

Updated: 2026-09-07. Owner: integration/UI (Atlas/Pixel scope), local Apple Silicon
Mac. Receiving roles: Pixel for attended reproduction/playback; Atlas for native
integration; Harbor only after a separately authorized delivery. Role files and
Orca are absent; a standard isolated worktree is used.

Branch: `youzi/live-voice-stall`, based on installed candidate `8b11044e` because
this is a follow-up regression. Main and other worktrees are untouched. No main
merge, installed bundle replacement or public release is part of this task.

## Verified facts

- The user's native process hung in main-thread SwiftUI graph/lazy placement
  work. Backend endpoints still responded. Exact original text/PCM timestamps
  and the precise layout trigger remain unknown.
- Existing native orchestration starts sentence TTS while chat is streaming;
  HTTP speech consumes incremental PCM, not a whole WAV. A same-port synthetic
  probe observed first PCM14.339s, LLM completion22.139s. See the performance
  document for request-parameter differences and strict evidence limits.
- Candidate changes: stable eager transcript layout; deferred/cancelled scrolling;
  no auto-follow under voice sheet; bounded sheet transcript height; deduplicated
  preview/stage updates; truthful stage labels and first-text/PCM diagnostics.
- Native regression and offscreen layout QA are recorded in the completion
  checkpoint below. They are not actual speaker or full-duplex acceptance.
- The old hung process later exited without this task terminating it. Another
  local build was then serving port8000 with chat only. No current audio models
  were started, no configuration or installed client was changed, and no force
  termination was performed.

## Risks / remaining work

1. Reproduce with the actual task under an attended full candidate and verify
   responsive controls, text/PCM overlap, audible playback and Stop/microphone-off.
   Do not declare the exact hang fixed solely from the offscreen test.
2. Rerun the enhanced native HTTP harness with
   `YOUZI_LIVE_RENDER_TRANSCRIPT=1`, already-serving audio lanes, isolated defaults
   and an empty output directory. It was not run after runtime ownership changed.
3. Measure long-task eager layout cost; current QA covers116 messages only.
4. Serial per-sentence playback drain still permits inter-sentence synthesis gaps.
   No sentence prefetch or incremental ASR was added; acoustic AEC is unqualified.
5. Any eventual installation needs the existing fresh paired native+sidecar build,
   whole-bundle backup/replacement and signature checks. Reconfirm the running
   executable and permission before stopping it. Never patch a sealed bundle.

Every native command uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`. No model downloads,
unloads, automatic-pool edits, port sweeps, user store resets or permission changes.

## Completion checkpoint

- Release compilation succeeded with Apple Swift6.3.3 on macOS26.6.2.
- Targeted run:65 test entries passed,3 opt-in tests skipped (68 discovered).
- Separate opt-in offscreen layout QA passed in3.414s under the60s external
  deadline, covering116 messages. This is rendered fixture QA, not the user's
  actual task or a physical speaker test.
- Deadline wrapper checked with isolated fake children: success, nonzero exit,
  invalid timeout and forced deadline all propagated expected status.
- `git diff --check` and Python AST parsing passed. Existing unrelated compiler
  warnings remain; no warnings were suppressed as a workaround.
- Enhanced real-model HTTP rendering and installed GUI verification remain
  explicitly pending. Detailed repro commands/results are in the existing
  live-voice operations and performance documents.

## Thinking follow-up

Source/config review: native chat defaults thinking off; the stored switch was
absent. The standalone Responses benchmark omitted the switch, which is a
measurement caveat, not proof that it reasoned. Four read-only current-service
requests (Responses and chat, unspecified/off) all returned visible text within
0.185–0.578s and no observed reasoning; Responses usage reported0 reasoning
tokens. Cached prompt tokens and output lengths differed. See the performance
note for exact payload conditions, numbers and reproduction artifact location.
No source or user setting was changed. The earlier13-second first-text delay's
cause remains unproven; the layout stall remains a separate confirmed symptom.
