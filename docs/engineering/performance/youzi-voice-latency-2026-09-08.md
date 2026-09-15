# LLM → TTS → output timing — September 8, 2026

## Scope and ownership

Measurement owner: Vector role, local Apple Silicon Mac. Role files/Orca are not
present in this checkout; work uses a standard isolated Git worktree on
`youzi/voice-latency-timeline`, based on `f12430cd` for the current production
sentence segmenter. No product code, settings, installed bundles, or model files
were changed. Runtime remediation belongs to Atlas; see the handoff.

This is **not** an installed-GUI or acoustic full-chain acceptance. No microphone,
ASR, echo cancellation, UI scheduling, chat history, or tool execution is involved.
The built-in MacBook Pro speakers were **muted** (CoreAudio mute=1, master volume
~0.875); settings were not changed. Actual acoustic sound onset was therefore not
measured, and this run did not audibly speak.

## Important runtime mismatch

The running backend used the `Rapid/runtime-override` sidecar, whose VERSION marker
was `0.13.3`. A marker alone is not proof of implementation: corroborating evidence
was collected from its live OpenAPI schema, actual HTTP responses, and the
`create_speech` code object of its on-disk `routes/audio.pyc` (read without executing
that bytecode):

- `AudioSpeechRequest` has **no `stream` field**.
- TTS returns `audio/pcm`, 24000 Hz, mono, fixed `Content-Length`, and no
  `X-Audio-Format: pcm_s16le` header.
- The route references `run_to_completion`, `_generate_speech_blocking`, and
  `Response`, not `_stream_speech_pcm` or `PCMStreamingResponse`.
- Audio route SHA-256:
  `40ad039a3b4347b87fe7efc89aa7877c73624bf56df9a91e852319147c37a632`.

The strict streaming probe failed on the protocol mismatch. It was **not** made to
silently accept the old protocol. A separately opted-in, bounded legacy downloader
was then used to measure the real old service's complete-sentence response and
output playback. This fallback exists only in the benchmark. It does not bypass or
change the application's `AudioClient.streamSpeech` validation.

Consequently: **LLM streaming works in these requests; model-level TTS streaming is
not implemented by the backend measured here.** Client-side chunking of a buffered
response does not fix that. These findings supersede assumptions based on the
previous process's different runtime; they do not invalidate older measurements of
that different process.

## Environment and request

- Mac17,7, 128 GiB unified RAM, macOS 26.6.2; Apple Swift 6.3.3.
- LLM: `qwen3.8-27b-4bit` (Qwen3.8 27B 4-bit, vision serving lane).
- TTS: `qwen3-tts`, resolving to Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16;
  explicit `vivian` voice, speed 1.0, PCM16 / 24 kHz / mono.
- `/v1/chat/completions`: `stream=true`, `temperature=0.3`, `max_tokens=400`,
  `chat_template_kwargs.enable_thinking=false`, usage enabled.
- Prompt: `请用六句简短中文介绍李白的静夜思及其含义。每句话以句号结尾，第一句不超过十五个字。不要标题、Markdown或工具，直接讲解。`
- Synthetic short-answer calibration, not representative of all workloads.
- Both accepted runs had 48 input tokens and 33 cached input tokens; outputs were
  44 and 50 tokens respectively. Both reported 0 reasoning characters.
- LLM was already serving. TTS was downloaded but initially not resident. An
  explicit authenticated preload with `preserve_loaded=true` took **156.626 s**.
  It ran before the timed LLM requests. Its internal initialization/weight-loading/
  locking/network-check components were not separately profiled. No attribution
  to a particular substep is supported. No other resident model was unloaded.

## Accepted observations

Seconds relative to the LLM request, one `mach_absolute_time` clock:

| Milestone | A | B |
| --- | ---: | ---: |
| First non-whitespace text | 0.378 | 0.429 |
| First sentence ready | 0.661 | 0.721 |
| First TTS request | 0.661 | 0.722 |
| First PCM received by URLSession delegate | 1.560 | 1.641 |
| First complete PCM response received | 1.560 | 1.641 |
| First PCM frame enqueued | 1.560 | 1.641 |
| First mixer sample above -60 dBFS | 1.690 | 1.775 |
| LLM `[DONE]` | 2.870 | 3.151 |
| First sentence playback drain | 5.124 | 5.291 |
| Whole probe completion | 21.561 | 25.493 |

First-sentence breakdown:

| Stage duration | A | B |
| --- | ---: | ---: |
| LLM → first text | 0.378 | 0.429 |
| First text → sentence ready | 0.283 | 0.293 |
| Sentence ready → TTS request | <0.001 | <0.001 |
| TTS request → first PCM | 0.898 | 0.919 |
| First PCM → receive complete / enqueue | <0.001 | <0.001 |
| Enqueue → first non-silent mixer sample | 0.130 | 0.134 |

First rendered speech preceded LLM completion by 1.181/1.376 s. Thus these
requests did not wait for the entire LLM answer. This does **not** demonstrate
model-level streaming TTS: the old backend completed each sentence before return.

The probe reproduces the inspected controller's serial sentence policy: wait for
playback drain before starting the next sentence's TTS request. Measured gaps from
the previous drain to the next non-silent render ranged **0.592–1.335 s** across
these two requests. Next-sentence prefetch is a potential remediation, not an
implemented or benchmarked improvement. Do not infer stable medians/P95s or causal
thinking/cache effects from two varying outputs.

## Measurement design and discarded calibration

- Reuses `LiveVoiceSentenceSegmenter.swift` directly when compiling the standalone
  Swift executable. No Markdown/reasoning is supplied to TTS.
- Output-only AVAudioEngine + AVAudioPlayerNode; no input node. PCM is enqueued in
  100 ms frames, paced to at most ~1.5 s outstanding playback.
- Nonisolated `@Sendable` SDK callbacks inspect borrowed PCM synchronously. Shared
  callback metadata is locked; no borrowed buffer is dispatched to an actor/task.
- First non-silent time is tap buffer host time plus the first >-60 dBFS sample's
  offset. Raw events separately preserve when that callback was observed.
- Taps may be delayed and contain samples from an earlier segment. Classification
  begins only at the first enqueue and rejects samples older than that host time.
- `.dataPlayedBack` tracks **completion**, never first-sound onset. The system
  reported downstream presentation latency of 1.25 ms; this is not a calibrated
  acoustic delay and is not substituted for an actual speaker measurement.
- An initial muted-device refusal and a strict-protocol failure are retained.
- Two initial output-probe calibration runs are explicitly marked
  `invalid_probe_measurement`. Per-byte async receipt added measurement overhead,
  and a delayed tap could be attributed to the following sentence. They are not
  used in metrics/comparison charts. The accepted legacy measurement timestamps
  chunk arrivals/EOF directly in a serial URLSession delegate and uses the
  first-enqueue host-time gate above. No evidence was silently overwritten.

## Reproduce safely

The probe uses fixed loopback port 8000 and model aliases above; it does **not**
load/download/unload models, obtain credentials, change preferences, or start an
app/backend. Prepare already-downloaded resident models using normal application
controls first. An optional `YOUZI_PROBE_API_KEY` environment variable supplies
inference authorization; it is never written to output.

```sh
OUT=/tmp/youzi-voice-latency
mkdir -p "$OUT"
RAPID_DESKTOP_NO_PORT_SWEEP=1 swiftc -swift-version 6 -O \
  scripts/benchmarks/youzi_voice_playback_probe.swift \
  apps/rapid-mac/Sources/Rapid/LiveVoice/LiveVoiceSentenceSegmenter.swift \
  -o "$OUT/playback-probe"

# Strict streaming contract is the default. Output playback requires opt-in.
export RAPID_DESKTOP_NO_PORT_SWEEP=1 YOUZI_OUTPUT_PLAYBACK_PROBE=1
# ONLY for an explicitly labelled muted software-rendering test:
export YOUZI_ALLOW_MUTED_RENDER_PROBE=1
# ONLY for the confirmed old buffered endpoint, NOT streaming qualification:
export YOUZI_ALLOW_BUFFERED_TTS_PROBE=1

# Bound the probe's own process group, never the app/backend or arbitrary ports.
python3 - <<'PY'
import os, signal, subprocess
p = subprocess.Popen(['/tmp/youzi-voice-latency/playback-probe',
    '/tmp/youzi-voice-latency/run-new', 'manual repeat'], start_new_session=True)
try:
    p.wait(timeout=180)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGTERM)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait()
    raise SystemExit('Probe timed out; only its process group was stopped')
raise SystemExit(p.returncode)
PY
PYTHONDONTWRITEBYTECODE=1 python3 scripts/benchmarks/test_youzi_voice_latency_report.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/benchmarks/youzi_voice_latency_report.py "$OUT"
```

Artifacts for this run: `/tmp/youzi-voice-latency/`:
`preload.json`, `runtime-evidence.json`, `run-5/results.json`,
`run-6/results.json`, per-sentence PCM/WAV, and self-contained `index.html`.
The HTML includes actual Gantt timelines, first-sentence zoom, run switching,
audio replay (synthesized PCM, **not** microphone recording or original delays),
and raw JSON download. Raw failed/calibration attempts remain available.
Temporary artifacts/binaries are not committed.

Verification: optimized Swift 6 compile; two accepted six-sentence real service /
output-engine lifecycles; causal ordering checks for all 12 sentences; seven
successful offline report/evidence tests. Browser QA passed for 1280px/390px
layouts, run switching, timeline zoom, and raw JSON export. Embedded WAV metadata
decoded without starting playback; browser console had no errors/warnings.
The handoff records the temporary artifact locations. No client replacement/restart/release was performed.
