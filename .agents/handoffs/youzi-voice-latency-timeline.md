# Voice latency measurement handoff

- Sender: Vector / local Mac performance task.
- Receiver: Atlas (runtime/client integration), then Vector for retest.
- Branch: `youzi/voice-latency-timeline`, based on `f12430cd`.
- Product changes: none; standalone probe, report generator/tests, measurement doc.

## Verified

See `docs/engineering/performance/youzi-voice-latency-2026-09-08.md` for environment,
commands, discarded calibration, timing semantics and evidence fingerprints.

Current runtime-override marker 0.13.3 exposes a **buffered** TTS route despite
`stream:true` requests. Live OpenAPI lacks `stream`; actual response lacks the new
format header; the current route's code object uses complete-generation + Response.
The strict streaming probe correctly refuses it. This is not equivalent to the
previous process/runtime's streaming test results.

A separately opted-in legacy probe achieved first mixer non-silent render at
1.690/1.775 s, ahead of LLM completion at 2.870/3.151 s, with thinking explicitly
false and zero reasoning characters. All 12 sentence timestamp ordering gates
pass. The output device was muted: **no actual acoustic sound-onset acceptance**.
TTS preload before testing took 156.626 s; internal cause remains unprofiled.
Sentence-serial playback produces measured 0.592–1.335 s gaps.

## Risks / next concrete action

1. Compare the running override's identity and capabilities against the intended
   client/sidecar pairing. Propose a recoverable whole-bundle/runtime update;
   don't patch an installed bundle or delete the override in place.
2. Preserve resident LLM/TTS and all user preferences. No app restart or release
   was performed/authorized by this measurement task.
3. After a compatible runtime is selected with user authorization, rerun the
   **strict** probe without legacy fallback, plus the actual GUI route. Retain
   thinking/cache/sampling conditions and distinguish network consumption time.
4. Profile the 156.626 s load separately. Consider bounded next-sentence TTS
   prefetch only after protocol correctness is fixed; not yet implemented.
5. Ask for an attended, unmuted output test. Acoustic onset/AEC/full-duplex remain
   unverified; never enable microphone or change output settings implicitly.

Validation: Swift 6 optimized standalone compilation, two accepted real-model
output runs (no input node), 12-sentence ordering gates, seven offline report
checks. Browser QA passed at 1280px and 390px (no document horizontal overflow;
the chart scrolls within its container), run switching, first-sentence/full
zoom, and JSON export (six retained attempts, two completed measurements).
Embedded WAV metadata decoded successfully (16.08 s for run A); playback stayed
paused and no output setting changed. Browser console: zero errors/warnings.
Generated HTML, audio, JSON and QA screenshots remain under
`/tmp/youzi-voice-latency/`; only the report directory is served on loopback port
8769 for this temporary delivery.
