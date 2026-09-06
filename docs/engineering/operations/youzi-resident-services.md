# Youzi resident model services

Status: development implementation, validated locally on 2026-09-06. This is not
an assertion that a public release already contains the feature.

## User workflow

Open **Settings → Models → Model service → Resident model services**.

1. Download the models and their runtime assets under Model Files first.
2. Enable **Restore resident models when chat starts**.
3. Choose one transcription, one speech, and one image-generation model. Only
   cached models with the required catalog capability are offered. A saved model
   that disappears remains visible as unavailable; no automatic download occurs.
4. Start the chat model, then choose **Load resident set**. On subsequent chat
   service starts the selected media set is restored automatically. Enable the
   existing chat auto-start option for restoration when opening the app.
5. Check the per-model ready/loading/busy/failure status. These are backed by
   residency data, not merely the presence of audio routes.

Preferences persist immediately, like the surrounding startup settings. Changing
selections while a restore is running applies to a subsequent restore; it does
not cancel a GPU allocation already in progress. Disabling restoration or clearing
one selector does not unload an already running model. Model Files still owns
installation and deletion, and the existing service stop action stops the whole
process.

Chat uses the current selected primary model; this is not a second independent
chat-model configuration. Dynamic video residency is not supported. This first
version is one selected STT lane, one selected TTS lane and an image model beside
the primary chat model, not unlimited same-lane checkpoints or all downloaded
models. Explicit inference/selection of a different audio model still replaces
that same audio lane; it does not replace chat or the other media lanes. API
callers should specify the desired model ID rather than assuming that the legacy
`default` alias follows the desktop resident selector.

## API and lifecycle

- One service address and existing API-key policy, shared by all models.
- `POST /v1/audio/models/load`, body `{"model":"<audio alias or HF ID>"}`:
  authenticated management endpoint, preloads the exact caches/Metal worker used
  by speech/transcription. It does not synthesize a test sentence or transcribe
  dummy audio. HTTP 200 reports a materialized audio-worker lane.
- `POST /v1/models/load` remains the chat/image control plane. Resident image
  selection requests `pin: true`, including when the image was already loaded.
  The primary chat model is protected by its existing primary/pin policy.
- `/v1/models` retains its OpenAI list envelope and existing capability extensions.
  Actual resident/busy audio caches contribute canonical IDs and registered
  aliases; loading, failed and merely registered lanes are excluded.
- Inference continues through `/v1/responses`, `/v1/chat/completions`,
  `/v1/audio/speech`, `/v1/audio/transcriptions` and `/v1/images/generations`,
  routing by `model`.
- Allowing anonymous inference does **not** make load/unload management anonymous.
  The desktop uses its existing internal credential. No new public key store or
  frequently rotated key is introduced.
- Unsupported media loading and capacity refusal surface per-model errors; they
  do not fall back to stopping the healthy primary process. Media loads omit
  chat-only performance overrides. The image retry button no longer stops the
  entire service.
- Startup restores sequentially to reduce allocation spikes and continues past
  failed/missing selections. Process identity and restore tokens prevent results
  from an old service being applied to its replacement.

## Resource and readiness boundaries

Simultaneous residency does not promise unrestricted parallel GPU execution.
Inference retains the existing worker/locking rules. Only selected images are
pinned by this setting; ordinary unpinned secondary models retain the runtime's
existing LRU behavior.

Audio preload requires cached `.safetensors` or Whisper `.npz` weights. Admission
estimates weight bytes × 1.25 + 512 MiB, bounded by host available memory and the
residency manager's reported available ceiling. This is a conservative preflight,
**not an atomic cross-lane allocation reservation or a guarantee against OOM**.
Same-lane replacement may unload the outgoing audio model before a new engine
fails; other lanes are preserved. Do not promise rollback of the outgoing audio
engine on arbitrary load failures.

Whisper may load weights without a tokenizer/processor in mlx-audio. Explicit
preload now rejects that known unhealthy state with HTTP 409 instead of reporting
ready. Repair its associated processor files before selecting it again. A
complete model weight snapshot alone is not proof that every external runtime
asset is installed. Other model families/voices still require their own tests.

The shared audio worker does not expose trustworthy per-model memory bytes.
Desktop displays `VOICE · —` with an explanation rather than inventing a 1-byte
allocation; audio residency still contributes to the multi-modal status badge.

## Verification

Never sweep the user's live inference port during tests:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'YouziMediaCoLoadTests|YouziResidentServiceTests|ModelResidencyTests|LaunchMediaResidencyTests'
swift build --package-path apps/rapid-mac -c release
python -m pytest -q tests/test_youzi_audio_preload.py \
  tests/test_youzi_loaded_models.py tests/test_audio.py \
  tests/test_audio_output_format.py tests/test_audio_model_worker.py \
  tests/test_audio_served_tts_default.py tests/test_resident_models.py
```

Local evidence: 47 Swift tests in four suites passed; 177 Python tests passed,
four skipped (including the optional SDK test in the Python unit-test environment).
The official SDK was separately exercised against the real isolated server.

Real smoke environment: Apple M5 Max, 128 GiB unified memory; isolated loopback
port 8002; existing user service left running. Runtime cloned from the installed
runtime and verified against base commit `c32379fe` before applying only changed
Python modules. This is **not a clean-room sidecar rebuild**. No model downloads
were performed; `HF_HUB_OFFLINE=1` was set. Start the isolated runtime with:

```sh
HF_HUB_OFFLINE=1 rapid-mlx serve qwen3.8-27b-4bit \
  --host 127.0.0.1 --port 8002 --enable-audio --no-spec-decode \
  --resident-memory-limit-gb 60
```

Use a separate unused port, not the user's service. This no-key loopback command
is an isolated test fixture, not a recommendation to expose unauthenticated
management on a network. Do not copy private keys into logs or shell history.

Verified selected set:

| Lane | Model |
| --- | --- |
| Chat | `qwen3.8-27b-4bit` |
| Speech | `qwen3-tts-4bit` (Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit) |
| Transcription | `whisper-large-v3-turbo` |
| Image | `z-image-turbo` (mflux 4-bit) |

Reproduce by preloading both audio IDs through the audio load endpoint, and the
image through the generic endpoint with `pin: true`, `estimated_size_gb: 8` and
`image_mode: "generation"`. Then run a synthetic chat, synthesize a WAV with
Qwen voice `vivian`, transcribe that WAV in Chinese with Whisper Turbo, and request
a 512×512 image. Inspect `/v1/models/residency` after each operation. All four
engines remained resident and `evictions_total` stayed zero. These requests were
sequential; this is functionality evidence, **not a concurrency benchmark**.

Official OpenAI SDK model listing included all four engines and their supported
aliases. Non-streaming Responses returned `READY_OK`; streaming Responses emitted
`STREAM_OK` and a completed event. An incomplete Whisper Small preload returned
409 and did not remove the primary/image/TTS models. Whisper Turbo transcribed
the generated sentence as `柚子多模型服务已经就绪`.

For rollout/rollback, follow [the local delivery runbook](youzi-delivery.md):
back up the complete app and active override, verify both runtime locations, and
re-sign the full candidate. Source changes or a Swift-only build do not update
the installed sourceless runtime. Public packaging, publishing and app restart
are separate delivery actions and must not be inferred from these test results.
