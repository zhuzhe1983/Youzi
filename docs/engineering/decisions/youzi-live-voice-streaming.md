# Live voice uses the real chat pipeline and bounded PCM

Status: candidate implementation, 2026-09-07. Owner: Atlas integration.
Physical acoustic acceptance remains an attended gate, not an inferred success.

## Problem

The previous dictation/TTS flow captured a whole utterance and returned a whole
encoded audio file. A streaming model underneath that route did not make the
client streaming. Replacing it with an unrelated demo chat would also bypass
Youzi's expert/skill/tool confirmations, attachments and task persistence.

## Decision

1. Keep utterance/window HTTP ASR. Local amplitude endpointing supplies bounded
   16kHz mono recordings; this is **not native incremental ASR**. An explicit
   finish-utterance action avoids waiting for silence when needed.
2. Reuse `ChatViewModel.send` and its existing streaming, tool and persistence
   pipeline. Resident-only voice sends must not implicitly start/download models.
   Each send/regeneration gets a turn identity; voice owns only the turn it sent.
3. Project assistant **content** deltas into short sentences. Suppress fenced
   and inline code, structured JSON and explicit reasoning blocks. Never feed
   reasoning fields or tool arguments to TTS. Bound pending text; on overload or
   a rewritten response, stop speech and leave the original chat available.
4. Each sentence is complete input to Qwen but produces real incremental PCM.
   This is sentence-fed text / streamed waveform, not arbitrary-token duplex TTS.
   Keep existing buffered WAV/MP3 requests compatible and opt in via
   `stream:true,response_format:"pcm"` on `POST /v1/audio/speech`.
5. The candidate PCM route initially supports reference-free Qwen3-TTS only,
  24kHz mono signed16-bit little endian. Explicitly reject unsupported streaming
   formats/rates/channel layouts/families/cloning instead of pretending one
   buffered file is a stream. Startup failures remain ordinary JSON errors.
6. Keep a residency lease and lane lock for the whole generator lifetime. Create,
   advance, materialize and close it on the owning model worker. Yield the worker
   between chunks so a slow network consumer cannot block the LLM worker in a
   producer queue. Cancellation drains an in-flight step before releasing locks.
7. Native transport uses `URLSession.bytes(for:)`, validates the PCM contract,
   handles sample boundaries split across packets and feeds bounded buffers.
   Neither `data(for:)` nor a complete temporary WAV sits on the playback path.
8. One `AVAudioEngine` owns capture and an `AVAudioPlayerNode`; enable Apple voice
   processing before format/tap setup so the engine has the playback reference.
   No engine/microphone activation at app launch or when opening the sheet.
   Explicit user start and macOS microphone consent are required.
9. AEC initialization failure is visible and does not silently enable unprocessed
   full duplex. The user can explicitly choose half duplex: input frames are
   ignored while replying, and a stop/interrupt button returns to listening.
   Half duplex is not an acoustic guarantee or a hardware mic-off indicator.
10. Interruption invalidates generation/playback epochs and cancels only the
    owned chat turn. Late PCM or callbacks cannot revive old speech. Dismissal,
    navigation, app background/termination and device changes stop capture.
    Tool approval hands off to the original chat UI with microphone/playback off.
11. A continuous utterance reaching15s stops capture with visible guidance; it
    never submits a capped partial command. Speech queues are bounded by96
    segments and6000 characters; overflow hands off to text without cancelling
    the remaining chat/tools. Short headings/poem lines must not trip a24-line
    cap during ordinary explanations.
12. The existing non-Qwen Python iterator API keeps its prior calling convention.
    It does not gain the HTTP streaming qualification: Kokoro, Base/VoiceDesign
    and unsupported families are rejected before the live-voice mic starts.

## Protocol extension

```json
{"model":"qwen3-tts","input":"你好。","voice":"Vivian","stream":true,"response_format":"pcm","streaming_interval":0.32}
```

Successful streaming response has no Content-Length, content type
`application/octet-stream` and these headers:

```text
X-Audio-Sample-Rate: 24000
X-Audio-Channels: 1
X-Audio-Format: pcm_s16le
Cache-Control: no-store
X-Accel-Buffering: no
```

`stream` and `streaming_interval` are Youzi extensions. They do not change
`/v1/models`, auth configuration or existing non-streaming semantics. HTTP auth
and route validation still apply. Mid-stream synthesis failure closes the stream;
a partial raw PCM stream has no encoded duration/checksum, so EOF cannot by itself
prove acoustic completeness. The native client must surface transport/format
errors instead of replaying partial data as a cached success.

## Tradeoffs / deliberately not promised

- VAD endpoint silence, ASR, safe sentence boundaries, GPU contention and device
  buffers all add latency. Isolated first model PCM is not voice-to-voice latency.
- Current energy endpointing can be affected by room noise; no claim of neural
  continuous VAD/ASR. Half-duplex and explicit finish/interrupt are fallbacks.
- Acoustic AEC/double-talk quality must be measured with actual devices, room
  acoustics and speaker volume; an OS enabled flag is only initialization state.
- TTS per-sentence resets may affect prosody. Evaluate by listening, not only
  waveform duration or successful HTTP response.
- Alternate GGML CPU and true incremental ASR are future independent work, not
  prerequisites for this bounded MLX candidate.

## Evidence

- `tests/test_audio_pcm_streaming.py`
- `apps/rapid-mac/Tests/RapidTests/YouziLiveAudioCoreTests.swift`
- `apps/rapid-mac/Tests/RapidTests/YouziLiveVoiceTests.swift`
- `apps/rapid-mac/Tests/RapidTests/YouziLiveVoiceHTTPTests.swift`
- `scripts/benchmarks/youzi_qwen_tts_stream.py`
- `scripts/benchmarks/youzi_live_voice_chain.py`
- `docs/engineering/performance/youzi-live-voice-2026-09-07.md`

## Completed-message corrections

A chat message reaching its finish reason does not necessarily complete the
whole tool/chat turn. Existing grounding recovery can clear and rewrite that
same message ID. Speech must therefore continue validating completed projections,
not merely skip them after sentence flush. Text replacement, removal, reopening
or revoked speakability invalidates queued/in-flight PCM and hands off to text
without cancelling the correcting chat. Repeated unchanged completed snapshots
must remain idempotent. Regression tests cover both completed and partial cases.
