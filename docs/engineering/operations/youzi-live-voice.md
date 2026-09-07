# Youzi live voice — developer candidate and attended acceptance

Owner Atlas; local Apple Silicon Mac. The source is a developer candidate, not
an assurance that a public release already contains it. Architecture and measured
performance live beside this document under `decisions/` and `performance/`.

## Use

1. Load a chat model, an STT model (tested: Whisper-large-v3-turbo), and a
   reference-free Qwen3-TTS CustomVoice model using existing model controls.
2. In either simple-task or professional chat, open **Live Voice / 语音对话**.
   Opening it must not request microphone permission or record.
3. Choose system voice processing or explicitly enable **Half duplex / 半双工**.
   Press **Start / 开始**. The OS microphone permission is required.
4. Speak a short request; pause about650ms or press **Send Utterance / 说完了**.
   The utterance is recognized once, then the existing chat pipeline streams its
   reply; safe sentences are synthesized as incremental PCM, not a full WAV.
5. Press **Interrupt & Speak / 打断并继续说**, or try acoustic barge-in with system
   processing. Half duplex ignores input during recognition/replies; press
   Interrupt before speaking again. It does not physically switch the mic off.
6. End, close, navigate away, switch conversation/model, background the app or
   change audio devices: microphone/playback must stop. A tool requiring consent
   closes capture and returns to its original confirmation UI. No voice-specific
   approval bypass or automatic model download is provided.

Transcripts and ordinary assistant/tool messages remain in the current task.
Raw microphone recordings are transient and are not saved. Default speaker and
speed come from the existing per-model Audio settings. The tested streaming
speech family is Qwen3-TTS CustomVoice; unsupported models are rejected before
microphone startup. Continuous speech at15s stops with visible retry guidance,
without submitting a partial command. Long queued speech falls back to text
without cancelling remaining tools. This is **not native incremental ASR**.

## Reproducible unattended checks

Always set `RAPID_DESKTOP_NO_PORT_SWEEP=1` for tests/build/launch on a shared Mac.
Use an isolated test defaults suite and conversation directory. Do not reset the
user's preferences, keychain, model caches or task data.

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'YouziLive|LiveVoice'
PYTHONDONTWRITEBYTECODE=1 python -m pytest -q tests/test_audio_pcm_streaming.py
```

Opt-in native HTTP chain (already-serving models, empty output directory):

```sh
mkdir -p /tmp/youzi-native-voice-run
RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_LIVE_VOICE_HTTP=1 \
  YOUZI_LIVE_VOICE_INPUT=/tmp/synthetic-request.wav \
  YOUZI_LIVE_VOICE_OUTPUT=/tmp/youzi-native-voice-run \
  YOUZI_LIVE_CHAT_PORT=8000 YOUZI_LIVE_TTS_PORT=18008 \
  swift test --package-path apps/rapid-mac --filter YouziLiveVoiceHTTPTests
```

Supply a short, single-utterance synthetic Chinese16/24kHz WAV requesting about
six sentences; a one-word answer cannot establish overlap with a still-running
LLM. Ports may be the same for a fully integrated candidate. The test does not
load models or start services. Optional `YOUZI_PROBE_API_KEY` stays in environment
memory and is never written to results. Admin residency auth remains mandatory. By default the probe uses public model
discovery plus an explicit readiness fixture for split-port experiments. Set
`YOUZI_LIVE_PRODUCTION_READINESS=1` with both ports pointing to the installed
candidate and a valid bearer to exercise **real authenticated residency refresh
and production model selection**. Server ownership is still synthetic: the test
never starts/stops the app's child. A failed admin request must fail readiness;
do not remove auth to make the probe pass. Both modes use synthetic capture and
drain, not actual speaker playback or OS consent presentation.

Results distinguish session-start first PCM from `first_pcm_after_capture_seconds`
(the interval after the last synthetic input frame). Do not present either the
first-PCM time of standalone TTS or a synchronous test sink's drain time as the
user's audible conversation latency.

`YouziLiveAudioCoreTests` has a separate opt-in live PCM cancellation test. Set
`YOUZI_LIVE_AUDIO_TEST_PORT`, `YOUZI_LIVE_AUDIO_TEST_MODEL` to the fully qualified
resident lane model ID, `YOUZI_LIVE_AUDIO_TEST_VOICE` and optional bearer. Its
preflight must find an already-idle lane. It defaults to authenticated
`/v1/models/residency` (`audio_lanes`), not the integrated server's `/health`, which
does not include lane details. Only a standalone test server with the explicit
health fixture should set `YOUZI_LIVE_AUDIO_PROBE_HEALTH=1` (`lanes`). There is no
automatic fallback on an authentication failure. A short alias differing from
the lane's canonical ID intentionally fails preflight rather than loading a
replacement.

## Required attended acoustic/device checks — not synthetic-test passes

- First-open privacy, explicit Start/End, denial and recovery. Check the macOS
  microphone indicator against the UI, including background and termination.
- Built-in speaker/mic at low/normal/high volume: at least10 turns, no speech
  detection triggered by Youzi's own voice; then double-talk and barge-in. Record
  device, volume, distance, environment, false interrupts and interruption delay.
- Verify audible first response precedes completion of a sufficiently long chat
  answer; inspect prosody across sentences. PCM arrival alone is insufficient.
- Bluetooth/wired/default-device switching and unplug mid-turn: visible stop,
  no crash/ghost microphone, no old PCM on restart.
- Half-duplex fallback after AEC failure; no silent unprocessed full-duplex retry.
- Expert and simple chat: task stays the same after the first and second spoken
  turn; file/expert/skill attachments retain their existing meaning. Exercise an
  approval-required read-only tool, explicitly allow and deny; see persisted
  tool result only after the original UI confirmation.
- Stop during ASR, text generation, synthesis and playback drain; immediately
  start another request. No old assistant audio or cancellation of a typed turn.

Until these are attended, describe AEC as **system voice processing implemented,
physical echo/double-talk quality unqualified**, not “full-chain fully verified”.

## Local delivery / rollback

Do not modify a sealed installed app. Build the complete sidecar from this source
before signing; `SKIP_SIDECAR=1` is not a deliverable. Verify strict codesign,
bundled CLI/imports and resource integrity. Confirm ServerLocator selected the
candidate bundle rather than a newer runtime override. Before a local replacement,
retain the entire old app in the existing Youzi Client Backups directory and
record its version/identity. Stop only the owned app/service, never sweep shared
ports or kill unrelated Python processes. Relaunch with the no-port-sweep flag.
If startup, resources or health fail, stop the candidate and restore the complete
backup app; do not reset settings or data. Formal release/main merge requires
separate authorization. Exact installation status is recorded in the task handoff.


### Delivered local candidate — September 7, 2026

Installed/restarted `0.14.4 candidate-8be52684` from the complete normal build,
including its freshly compiled sidecar and the separately committed tray card.
Strict deep signature/resource verification and candidate-only CLI/import smoke
passed before replacement and launch. The previous complete
`candidate-d56811c2` app is retained under
`~/Library/Application Support/Youzi/Client Backups/0.14.4-before-live-voice-20260907-151414/`.
No sealed resources, tasks, settings or keychain were reset. Launch used explicit
`open --env RAPID_DESKTOP_NO_PORT_SWEEP=1`, not implicit LaunchServices inheritance.

The installed bundle's child served the real same-port native HTTP chain with
production authenticated readiness. Known cached Whisper was explicitly warmed
using `preserve_loaded=true` after checking an idle/empty recognition lane;
existing chat/image/video/TTS models remained loaded. Startup preferences were
not changed. Both GUI chat modes opened the voice sheet with **Microphone off**
and an explicit Start button; no Start/permission action was taken, and the
original simple mode was restored. Seven health samples over60 seconds retained
the same healthy/ready app and service processes.

The existing InstallTracker heuristic produced a false "failed replace" warning:
it compares only the marketing version and plist mtime, so two different local
candidates both labelled0.14.4 look like a failed replacement. Candidate identity,
strict signature, bundled-runtime process path and real new PCM behavior verified
that installation actually succeeded. The warning was dismissed through its
session-only UI action; no tracking preferences were cleared. Harbor should
separately teach this heuristic about candidate/build identity. This is not a
streaming inference failure or evidence that the old app is still running.


## Mandatory native callback regression (2026-09-07 incident)

Before accepting another live-voice client, run the actual AVFAudio Objective-C
callback bridge, not only the injectable controller or native HTTP fixtures:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 bash apps/rapid-mac/scripts/verify-live-audio-callbacks.sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac -c release \
  --filter 'YouziLive|LiveVoice|YouziTray|MenuBarStatus|YouziModelOccupancy'
```

The standalone script compiles the production engine/callback files with Swift6
and optimization. Optional `--negative-controls` deliberately crashes a **child
probe**, expecting SIGTRAP from the pre-fix tap pattern; it may create a system
diagnostic report. It then requires the fixed path to exit0. No microphone,
speaker, model service, credentials or application preferences are used.

The new callback suite covers the real tap/ObjC bridge across three offline
engine lifecycles; direct non-main callback execution; borrowed PCM copying;
overflow/shutdown; playback queue bounds/duplicates/stale epochs; notification
posting queues; and released owners. Offline player completion uses dataConsumed
only to exercise the block ABI; the product still waits for dataPlayedBack.
Do not mistake either offline rendering or generated HTTP audio for a physical
speaker/AEC qualification. The earlier installed candidate crashed despite those
HTTP/controller gates passing. See the full-duplex assessment for attended gates.
