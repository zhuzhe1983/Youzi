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
  Paired-bundle build/installation remains pending at this checkpoint.
- Current installed client is candidate-a6bb13f8, not this video-tool change.
- Every native test/build/launch uses `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
  Use isolated test preferences. Do not clear user caches/tasks/permissions or
  implicitly start models/microphone to manufacture acceptance.

## Risks and next actions

1. Native/Python regression passed; full diff reviewed, Python AST parse and
   `git diff --check` passed. Commit/push task branch before paired build.
2. Build paired native+sidecar from clean commit; verify signature/rpath/imports
   and mocked exact-identity API smoke. Do not patch a signed app in place.
3. Back up the current complete client, verify normal quit is safe, install the
   complete candidate and observe restart. Retain rollback bundles.
4. On unlocked attended device: actual LLM tool selection, startup consent,
   MP4 generation/playback, task association and Stop behavior. No acoustic
   full-duplex or inference-performance claims from mocks/idle startup.

Not addressed: audio/image interpretation tools, fully incremental ASR, acoustic
AEC/barge-in qualification, and multiple resident models within a single audio
lane. Public release/main integration requires explicit human authorization.
