# Atlas → Pixel / Harbor: local streaming voice candidate

Implementation branch: `atlas/youzi-live-voice-assessment`, based on
`atlas/youzi-model-settings` at47aca95f. Local-delivery branch:
`atlas/youzi-live-voice-delivery`, integrating voicefc49ece5 and tray8be52684. Atlas integration on the local Mac;
`.agents/roles/` is absent. Main is not changed by this task.

## Incident / current owner (supersedes the earlier delivery confidence)

On 2026-09-07 the installed `candidate-8be52684` crashed when real microphone
capture began: the AVFAudio tap's Objective-C block inherited MainActor isolation
and trapped on `RealtimeMessenger.mServiceQueue`. The earlier mock/HTTP passes
were real but **insufficient to qualify device startup**. Do not reinstall that
candidate as a verified voice build or describe AEC/full duplex as accepted.

Atlas/local Mac is repairing it on `atlas/youzi-live-voice-callback-fix`, based on
pushed delivery commit `6c81486e`. Explicit nonisolated Sendable callback factories
cover tap entry, playback completion and device-change delivery, preserving
MainActor UI/ledger access, weak owners, bounded PCM and stop epochs. No APIs,
models, settings, keychain, main branch or release metadata are being changed.

The real offline AVFAudio negative control reproduces the reported tap SIGTRAP;
the fixed bridge passes. Direct background Swift invocation alone did not
reproduce it. Playback completion is additionally exercised with software queue
and real offline ObjC callback tests, but **offline has no hardware presentation**:
its fixture uses dataConsumed; production retains dataPlayedBack. Full focused
Release regression passed: 73 tests in 10 suites (including 8 new callback tests).
Both optimized and unoptimized standalone real-ObjC probes reproduce legacy
SIGTRAP and pass the fixed callback. Native Release build passed. These tests
open no microphone/speaker and do not qualify acoustic AEC. Complete replacement
client packaging/installation is still pending and will be recorded separately.

Receiving Pixel/Atlas: [full-duplex assessment](../../docs/engineering/decisions/youzi-full-duplex-assessment.md)
records the current RMS-only insertion gate, native AEC/HAL VAD route, separate
half-duplex tail gap, device/near-end/double-talk acceptance matrix and unmeasured
latency targets. This is a follow-up proposal, not shipped AEC/VAD changes.

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

## Local delivery completed
- Full normal build, fresh matching sidecar, strict deep signing, resource verifier
  and bundled CLI/import smoke passed. Installed/restarted **0.14.4
  candidate-8be52684**; test/docs-only followup does not alter product binaries.
- Previous complete candidate-d56811c2 is retained in
  `~/Library/Application Support/Youzi/Client Backups/0.14.4-before-live-voice-20260907-151414/`.
  App/service exited gracefully before whole-bundle replacement. No settings,
  tasks, caches or keychain resets; explicit launch no-port-sweep flag verified.
- Both native GUI modes open/close voice sheet with Microphone off and explicit
  Start. No unattended Start/permission clicks. Original simple mode restored.
- Real installed-service native chain passed twice with authenticated production
  residency/model selection (server ownership and audio device edges synthetic).
  PCM preceded text completion; exact transcript and conversation reload passed.
  Warm repeat first PCM6.564s after the final input frame, not GPT-Live latency.
- Installed-service native PCM/cancellation test15/15 passed after correcting a
  test-only helper-health assumption; new default is authenticated production
  residency, never an auth fallback. Same-session recovery succeeded after exactly
  one cancelled callback. All audio lanes idle with no last error afterward.
- Same app/service health/ready stayed stable across7 samples/60.076s, signature
  still valid after use. Existing LLM/image/video/TTS preserved; cached Whisper
  explicitly warmed with preserve-loaded, no startup preference changed.

## Unresolved / next concrete action
Pixel/user: attended microphone consent/denial, audible multi-turn conversation,
built-in/Bluetooth device switching, double-talk/AEC and real tool-approval UI
checks from the operations checklist. Physical AEC remains **unqualified**;
never equate the engine's enabled voice-processing flag to acoustic success.

Atlas/Vector:6.564s measured post-input first PCM needs latency attribution and
optimization if the product target is live-assistant responsiveness. ASR is still
utterance/windowed, not native incremental. Current CPU1.7B BF16 Qwen result is not
realtime; quantized GGML CPU is not benchmarked. Unsupported speech families fail
before microphone startup. Do not claim all-model or all-device live support.

Harbor: separately fix InstallTracker's candidate identity handling. Same0.14.4
marketing version + changed plist mtime incorrectly warned that installation
failed; actual candidate identity, signature and bundled-runtime new streaming
behavior proved the replacement succeeded. Dismissed only the session's warning
through its existing UI; no tracking defaults cleared.

No main merge or formal release performed. Candidate remains on the dedicated
pushed delivery branch pending attended acceptance. Every Swift/test/build/launch
on this shared host must set `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
