# Youzi resident model services

Status: preferred-pool policy updated on 2026-09-07. This is not a claim that
all changes are in a public release. See [the policy decision](../decisions/youzi-model-selection-and-startup.md).

## User workflow

Open **Settings → Models → Service → Model loading policy**, or the corresponding
Chat / Audio / Image / Video tab.

1. Download models/runtime assets in Model Files.
2. Set downloaded models to **Automatic** or **On demand**. Automatic models form
   one ordered preferred pool per scene; there is no independent Default list.
3. Enable automatic loading with chat startup. Opening the app also requires chat
   auto-start and an automatic chat model; a previously used manual model will
   not be loaded just because it is in session history.
4. On a running service, **Load preferred pool now** explicitly restores the pool,
   including while startup loading is paused. This never downloads files.
5. **Save** applies the preferred pool to the live API without restarting models.
   Failure is shown; saved local intent is retained for retry/next service start.
6. Inspect readiness and allocation separately. The quick-picker check is ready,
   the bolt is automatic membership. Changing membership does not load/unload.

Unspecified calls reuse ready compatible pool members, in saved priority order.
Explicit calls target the exact model; native tools request approval before a
cold load. API callers must first load cold models through an authenticated
management endpoint; HTTP inference itself never grants that permission.

Multiple chat/image/video selections are supported subject to resource admission.
STT and TTS each still have one lane. Replacing their automatic selection changes
intent, not the active engine; a preserving load refuses an occupied same lane.
Video may be lazily registered, so ready is not proof of permanent GPU residency.
The service Stop action still stops the whole process. Selection changes during
an in-flight restore take effect for a later restore, not by cancelling an
allocation already in progress.

## API and lifecycle

- One service address and existing API-key policy, shared by all models.
- `PUT /v1/service/model-policy`, body `{"automatic":{"chat":["alias"]}}`:
  authenticated, policy-only replacement. Other scenes omitted from the object
  are empty. No registry mutation, load, unload, download or key rotation.
  It remains protected when inference is anonymous. The supervised child also
  receives the saved JSON in `YOUZI_AUTOMATIC_MODEL_POOL` at spawn.
- `POST /v1/audio/models/load`, body `{"model":"<audio alias or HF ID>"}`:
  authenticated management endpoint, preloads the exact caches/Metal worker used
  by speech/transcription. It does not synthesize a test sentence or transcribe
  dummy audio. HTTP 200 reports a materialized audio-worker lane.
- `POST /v1/models/load` remains the chat/image/video control plane. Resident image
  selection requests `pin: true`, including when the image was already loaded.
  The primary chat model is protected by its existing primary/pin policy.
- `/v1/models` retains its OpenAI list envelope and existing capability extensions.
  Actual resident/busy audio caches contribute canonical IDs and registered
  aliases; loading, failed and merely registered lanes are excluded.
- Inference continues through `/v1/responses`, `/v1/chat/completions`,
  `/v1/audio/speech`, `/v1/audio/transcriptions`, `/v1/images/generations` and `/v1/videos`,
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
Inference retains the existing worker/locking rules. Automatic generic model loads request preservation/pinning; ordinary unpinned secondary models retain the runtime's
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

## Historical multi-model verification (2026-09-06)

The following evidence predates the preferred-pool routing change. Rerun it with
explicit aliases or a configured pool for current acceptance; it is not a new
measurement of this policy revision.


Never sweep the user's live inference port during tests:

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac \
  --filter 'YouziMediaCoLoadTests|YouziResidentServiceTests|ModelResidencyTests|LaunchMediaResidencyTests'
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift build --package-path apps/rapid-mac -c release
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
back up the complete app and active override, build and verify a complete
candidate, then replace the whole bundle. Source changes or a Swift-only build do not update
the installed sourceless runtime. Public packaging, publishing and app restart
are separate delivery actions and must not be inferred from these test results.
