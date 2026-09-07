# Local voice measurements — 2026-09-07

## Scope and reproducibility

This is a **small synthetic smoke measurement**, not a statistical p95, audio
quality study or acoustic echo-cancellation acceptance. No microphone capture,
model download, user conversation export or model unloading was performed.
Running desktop load was not controlled. RTF = synthesis seconds / audio seconds;
below 1 means faster than real time for this sample, not a concurrency guarantee.

Environment: Apple M5 Max (Mac17,7), 128 GiB unified memory, 18 CPU cores,
macOS 26.6.2 arm64. Python3.12, MLX0.32.2, mlx-audio0.4.3, NumPy2.5.3,
Transformers5.15.1. Cached model:
`mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16`, snapshot
`52f4770fd9726457eae3d3b6aa92047a25a10776`, Vivian, Chinese, mono24kHz.

Use an existing compatible environment (the experiment used the installed
client's bundled interpreter and dependencies read-only):

```sh
PYTHONDONTWRITEBYTECODE=1 python scripts/benchmarks/youzi_qwen_tts_stream.py \
  --device gpu --model "$LOCAL_QWEN_SNAPSHOT" --interval 0.32 \
  --output /tmp/youzi-tts-gpu --timeout 180
PYTHONDONTWRITEBYTECODE=1 python scripts/benchmarks/youzi_qwen_tts_stream.py \
  --device cpu --model "$LOCAL_QWEN_SNAPSHOT" --interval 0.32 \
  --runs 2 --max-tokens 64 --output /tmp/youzi-tts-cpu --timeout 120
```

The script accepts a local directory, disables online lookup, isolates the model
in an owned child and bounds its lifetime. CPU mode forbids GPU default/explicit
streams. Timers include actual materialization to Float32 PCM, not lazy tensor
creation. Model load is separate from first-generation and warm measurements.
Generated speech is synthetic and saved only to the specified output directory.

## Model output streaming

| Device/sample | First PCM | Synthesis | Audio | RTF |
|---|---:|---:|---:|---:|
| GPU, first short generation (load excluded) | 0.324s | 0.769s | 1.92s | 0.401 |
| GPU, same short sentence warm | 0.086s | 0.532s | 1.92s | 0.277 |
| GPU, medium task description | 0.111s | 1.549s | 5.44s | 0.285 |
| GPU, poem plus explanation | 0.111s | 4.983s | 18.24s | 0.273 |
| CPU BF16, first short generation | 14.442s | 42.343s | 1.60s | 26.464 |
| CPU BF16, same short sentence warm | 6.878s | 34.810s | 1.60s | 21.756 |

GPU load0.571s; peak process RSS approximately4.70GB. The long sample emitted57
real320ms chunks, largest inter-chunk gap93ms. These isolated samples did not
require extra initial playback buffering. CPU emitted one320ms chunk about
every6.9s: **this specific1.7B BF16 CPU configuration is not real-time capable**.
Do not extrapolate it to quantized GGML/Metal or all CPU TTS engines.

An80ms interval experiment reduced warm first PCM to29–30ms, but the short
sample's RTF increased to0.367 (versus0.277 at320ms). Keep320ms as the conservative
initial route default; configurable80–1000ms interval is an extension, not an
OpenAI-standard field. No acoustic quality or GPU-contention conclusion follows
from this interval comparison.

## Real HTTP PCM transport

An owned probe on loopback18008 mounted the candidate's real audio route,
exception handlers and cached Qwen engine. It was not a fake generator. Original
client/service8000 remained untouched. Separate processes share the GPU, not a
single production model worker; this distinction matters for contention claims.

| HTTP sample | First nonempty network PCM | HTTP total | Audio duration |
|---|---:|---:|---:|
| First request, including model load |0.875s|1.452s|2.32s|
| Warm short sentence |0.089s|0.519s|1.84s|
| Poem and explanation |0.088s|6.210s|22.56s|

Network reads used `httpx.stream(...).iter_raw()`, not a buffered request.
An early socket close after the first15,360-byte chunk was followed200ms later
by a successful fresh turn in0.606s. The worker reported0 active requests and no
last error. Unit tests separately cover owner-thread close, repeated cancellation,
held leases and socket failure while the prefetched first chunk is being sent.

### Fresh packaged-runtime repeat

The same HTTP smoke was repeated from a freshly built, sourceless sidecar,
with cwd outside the checkout, Python `-P -B`, an explicit sidecar-only
`PYTHONPATH`, and offline Hugging Face/Transformers flags. Imports resolved to
candidate `.pyc` files, not the source checkout or installed app. This repeat
used the final repaired streaming backend and the same cached Qwen model:

| Request | First PCM | HTTP total | Audio duration |
|---|---:|---:|---:|
| Cold including model load |3.393s|3.805s|1.76s|
| Warm short |0.094s|0.417s|1.36s|
| Long |0.088s|4.195s|15.28s|

Disconnecting after15,360 bytes was followed by a successful fresh request
(61,440 bytes in0.367s). The lane returned to0 active requests with no error.
These are individual samples; differing speech duration/load timings are not
statistical regressions or throughput guarantees. The runtime build itself
skipped signing, so this test alone does not qualify an installable app.

## Synthetic ASR → streamed LLM → streamed TTS chain

```sh
python scripts/benchmarks/youzi_live_voice_chain.py \
  --chat-base http://127.0.0.1:8000 --tts-base http://127.0.0.1:18008 \
  --chat-model qwen3.8-27b-4bit --asr-model whisper-large-v3-turbo \
  --tts-model qwen3-tts --output /tmp/youzi-voice-chain
```

Optional `YOUZI_PROBE_API_KEY` is read only from the environment and is not saved.
Use endpoints with already-loaded models. The probe never calls model management.
It intentionally sets Responses `store:false` and uses a synthetic read-only tool.

Input synthetic speech: “请介绍静夜思，并解释这首诗的含义。”
Whisper-large-v3-turbo recognized it correctly (punctuation normalization only).

- Utterance/window ASR: **0.839s** (not incremental recognition).
- First actual `response.output_text.delta`: **0.363s** after LLM request.
- First response PCM: **1.137s** after LLM request (about1.98s after submitting the completed input WAV, excluding recording/silence endpointing).
- Whole LLM answer completed: **5.919s**. PCM therefore arrived while the rest of the answer was still generating.
- Eight sentence requests produced **41.12s** of audio; total ASR+LLM+TTS generation took16.339s (not playback time).
- Real function-call and matching `function_call_output` roundtrip completed; final answer correctly reported the synthetic fixture “ready, zero pending tasks”.

This probe proves overlapping HTTP stages. It is **not** the native controller,
not speaker playback and not the GUI's approval/persistence test. Concurrent LLM
load increased first-sentence synthesis time; single-engine latency is not a
promise for co-resident chat/image/video workloads.

## Native HTTP orchestration and repaired cancellation

The opt-in `YouziLiveVoiceHTTPTests` uses the real Swift controller, AudioClient,
ChatViewModel, chat streaming client, utterance ASR and incremental TTS endpoints.
Only readiness (an explicit test fixture),16kHz microphone frames and speaker
completion are simulated. Capture frames are fed at20ms cadence. Conversations
and defaults are isolated; reloading the conversation store verifies persistence.
The public model list is checked; the protected admin residency endpoint is not
weakened or bypassed in production.

Synthetic spoken request: “请用六句话简要介绍静夜思的含义。”
It was recognized exactly. Measured native run on2026-09-07:

- First PCM **8.185s from starting the test session**, including paced input
  playback-to-capture simulation, ASR, first sentence and TTS. This is NOT the
  isolated TTS latency, nor a measured human endpoint-to-ear latency.
- First PCM arrived **while ChatViewModel was still streaming**.
- **630 incremental PCM frames**,3,014,400 bytes /62.8s mono24kHz audio.
- Whole generation/drain-simulation run **36.834s**; returned to listening without
  controller error; original user and assistant messages persisted and reloaded.
- No actual microphone, speaker playback, GUI consent click or acoustic AEC test.

Initial real tests found an over-aggressive24-segment queue cap, now repaired
with96 segments plus the existing6000-character bound and regression tests.
A long-form explanation also exceeded the initial120s smoke-test budget while
still speaking; it is not presented as a completed pass. A two-clause WAV fed in
one synchronous callback cancelled its first VAD window; the probe now models
real frame cadence and uses a single explicit request. Final evidence is the
successful six-sentence run, not either failed experiment.

After restarting only the owned TTS probe with the repaired backend, the native
PCM client measured first PCM **0.130s**, completion3.232s for115 chunks /549,120
bytes. Cancellation after one callback followed by a fresh request on the same
URLSession succeeded (36 chunks /172,800 bytes); the lane returned idle.

Hermetic source checks at this checkpoint:53 native live-voice tests passed
(two optional network probes disabled);15 core tests passed with the live PCM
probe enabled. Independent backend review reran59 original/durable probes,
15 new cleanup/cancellation probes plus three repeat runs, and a broader suite
with245 passes and one independently confirmed pre-existing assertion mismatch
in the expected residency dictionary (`supports_preserve_loaded`). New code is
not excused by that baseline; all new backend findings were repaired and passed.

## faster-qwen3-tts and CPU/MLX compatibility

Primary source revisions inspected on2026-09-07:

- `andimarafioti/faster-qwen3-tts` `e2a215f61984c0e72a242f8dd72333338e7672f4` (0.4.0):
  https://github.com/andimarafioti/faster-qwen3-tts/tree/e2a215f61984c0e72a242f8dd72333338e7672f4
- `andimarafioti/qwentts-cpp-python` `b0b2da11293fb5a3f84fafc0a4c64524d7635b88`:
  https://github.com/andimarafioti/qwentts-cpp-python/tree/b0b2da11293fb5a3f84fafc0a4c64524d7635b88
- `ServeurpersoCom/qwentts.cpp` `6cb8a29c931b5d4d7f1301d2e8036bc5ce9cd00e`:
  https://github.com/ServeurpersoCom/qwentts.cpp/tree/6cb8a29c931b5d4d7f1301d2e8036bc5ce9cd00e
- Installed `mlx-audio0.4.3` implementation, cross-checked against
  https://github.com/Blaizzy/mlx-audio/blob/v0.4.3/mlx_audio/tts/models/qwen3_tts/qwen3_tts.py

The faster-qwen default Torch path explicitly requires CUDA; CUDA-graph speedups
are not directly usable on MLX. The project also has an experimental GGML backend
so calling the entire project “CUDA-only” would be wrong. The Python wrapper's
listed wheels target Linux CPU/CUDA, not a ready-made Mac MLX integration.
`qwentts.cpp` documents CPU, CUDA, Metal and Vulkan, quantized GGUF and streaming
PCM. It was not built or timed in this experiment. Its CPU potential remains an
independent benchmark, requiring matching converted weights and build validation.

Streaming waveform output must not be confused with accepting arbitrary text
tokens as they arrive: these inspected public generation APIs accept a complete
text string. The faster-qwen GGML notes explicitly exclude upstream
`non_streaming_mode=False` incremental text feeding. Youzi instead segments
incoming assistant content into safe short sentences and starts a streaming
Qwen request for each one. Existing MLX is sufficient for this architecture;
no CUDA dependency or speculative backend replacement is necessary.

## Acceptance boundaries

- Model and HTTP streaming: measured as above.
- Native byte framing, bounded audio queues and controller lifecycle: see the
  task's tests and operations handoff for final run results.
- Actual physical speaker/mic AEC, double-talk, Bluetooth route behavior,
  perceived prosody and attended GUI conversation: **not verified by these
  synthetic measurements**. An enabled OS voice-processing property is not an
  acoustic pass.

## Independent software acceptance

The backend review passed after three lifecycle/legacy-compatibility repairs:
59 focused/original adversarial tests,15 additional independent repair probes
(and three repeat runs),245 broad tests passing with one independently reproduced
pre-existing residency snapshot expectation failure.

The native review initially failed a real completed-message correction case:
queued old speech survived a same-ID grounding retry. After repairing ongoing
projection validation, the independent retry passed77 direct tests/12 suites,
30 unchanged external regression/adversarial tests, and the original failing
probe on a separate replay. Final fingerprints were stable. Builder focused
voice tests55/6 suites and final durable backend16 tests also passed.
These selections overlap: do not add their counts into a unique-test total.
One opt-in resident HTTP PCM test was disabled in the hermetic native run; its
separate real-service measurements are documented above.
