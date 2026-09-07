# Atlas → Pixel / Harbor: local streaming voice candidate

Task branch: `atlas/youzi-live-voice-assessment`, based on
`atlas/youzi-model-settings` at47aca95f. Atlas integration on the local Mac;
`.agents/roles/` is absent. Main is not changed by this task.

## Implementation
- Optional Qwen streaming PCM on the existing authenticated speech endpoint;
  owner-thread model iteration/cleanup, bounded transport and safe disconnect.
  Existing buffered HTTP and non-Qwen Python iterator behavior retained.
- Both chat surfaces expose an explicit-start voice sheet. Existing tasks,
  files, expert/skill prompts, tool approvals and persistence stay in charge.
- One native audio engine with system voice processing, bounded audio queues,
  stale-turn cancellation and actual playback-drain semantics. Explicit half
  duplex is available; no silent AEC fallback or startup microphone activation.
- Utterance/window ASR, streamed chat, sentence-fed streamed speech. Not native
  incremental recognition. No model download/start from the voice entrypoint.

## Evidence and repair history
Backend independent acceptance passed after cleanup-health, cancelled-factory
ownership and legacy Kokoro iterator compatibility findings were repaired.
59 focused/adversarial tests +15 new independent repair probes passed; broad
selection245 passes/1 independently reproduced stale residency-test assertion.

Native first independent review found completed-message rewrite could preserve
stale speech;75 direct native tests and27 isolated existing regressions passed,
but an independent correction probe failed twice. The repair adds continuous
validation of completed/revoked/removed projections and regression tests;
independent retry now PASSED:77 direct tests/12 suites,30 unchanged external
regressions/adversarial tests and a separate replay of the original failure.
The original failed review is retained in local acceptance history.

Real native HTTP orchestration with synthetic capture/drain proved exact ASR,
PCM before chat completion,630 chunks/62.8s generated audio and persistence
reload. It is not actual device playback. Fresh sourceless runtime imports and
real PCM/disconnect/recovery also pass. See the reproducible commands, model,
hardware and measured timings in `docs/engineering/performance/youzi-live-voice-2026-09-07.md`.

## Unresolved / next concrete action
Both software gates have passed. Next, Atlas must combine the separately committed tray resource card451f0d2c on a deliberate
local-delivery branch, sign/verify the complete matching app/runtime and retain
an intact old-app backup before restart. No main merge or formal release here.
Pixel/user performs attended first-open permission, audible conversation,
built-in/Bluetooth switching, double-talk/AEC and real approval UI checks.

Physical AEC quality is unqualified. Current CPU1.7B BF16 Qwen measurement is not
realtime; quantized GGML CPU is not benchmarked. Unsupported speech families are
rejected before microphone startup. Do not reset user data/settings/keychain or
modify a sealed installed bundle. Every Swift/test/build/launch on this shared
host must set `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
