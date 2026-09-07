# Preferred model pool — integration handoff

Updated: 2026-09-07. Owner: integration (Atlas), local Mac. Receiving roles:
Pixel for UI acceptance, Harbor for eventual release integration. Assigned role
files and Orca are absent in this checkout; standard Git task worktree used.
Branch: `atlas/youzi-model-loading-policy`, based on `dbd803c8` (delivered voice
callback fix). Main/workspace content is untouched. No public release authorized
or created by this task.

## Implemented contract

See `docs/engineering/decisions/youzi-model-selection-and-startup.md`.
Downloaded models have one ordered Automatic/On demand policy, separate from
readiness. No independent default-model routing remains. Omitted native media
calls use this pool, ready first; exact scenario choices stay exact. Startup
cannot enroll/load last-served or recommended models outside the pool. Legacy
single automatic aliases migrate by reading, without deleting rollback keys.
Native cold-load requests require interactive approval, never download.

Settings Save pushes authenticated policy-only updates to the current sidecar;
spawn gets the same owned environment payload. Chat/Completions/Responses,
Anthropic Messages/count_tokens, image/video, TTS/STT share routing. HTTP cannot
authorize cold loads: returns 409 until the model is prepared. Anthropic and
Responses metadata/tokenizer follow the selected model. Standalone CLI without
a desktop policy preserves existing compatibility behavior. Busy audio lanes
can queue, but readiness is rechecked inside the lane lock; a retired model is
not silently reloaded.

## Verification before bundled delivery

macOS arm64; Swift release configuration, `RAPID_DESKTOP_NO_PORT_SWEEP=1` on every
Swift test/build/launch. Python 3.12.13 / pytest 9.1.1 from an existing read-only
virtualenv; no dependency installation for testing.

- Native acceptance: **321 tests / 39 suites passed**. Selected suites cover
  residency, settings/Save, tools, startup, media co-load, session restore,
  voice callback regression and watchdog environment ownership.
- Opt-in SwiftUI snapshots inspected in Chinese and English: downloaded model
  names/search/size/status, priority badges and Automatic/On demand controls.
  Synthetic defaults only; user preferences not changed by visual tests.
- Python combined acceptance: **716 passed, 5 skipped, 1 pre-existing failure**
  across policy, auth, startup/residency, Chat/Responses/media, legacy completions
  and Anthropic compatibility suites. New policy suite: 32 passing tests.
- Baseline failure: `test_audio_routes_bundle.py::TestDeepProbeSurfacesDegradedLane::test_models_endpoint_surfaces_lane_status`.
  Expected audio-lane health on a legacy models entry; gets `None`. Reproduced on
  an exact `git archive dbd803c8` source copy using the same interpreter and test.
  No assertion removed/weakened. Needs a separate model-discovery follow-up.
- `git diff --check`; AST parse of changed Python files. No ruff/black available,
  so no formatter/linter pass is claimed.

Reproduce Python checks with `PYTHONPATH="$PWD" "$TEST_PYTHON" -B -m pytest -q`
and the relevant `tests/test_youzi_model_loading_policy.py`, compatibility,
residency and audio suites. Logs stay outside the repository.

## Delivery checkpoint / next action

At this checkpoint changes are ready for a clean-commit full sidecar+native build,
strict signature/import/API smoke, rollback backup and local replacement/restart.
Append the actual candidate and delivery results here after verification. Never
modify a signed installed bundle in place or let a stale runtime override shadow
this paired native/API change. Preserve all user data and preferences. Launch
with `open --env RAPID_DESKTOP_NO_PORT_SWEEP=1 -a ...`.

Current saved preferences have **no automatic chat member** and automatic startup
is not enabled. Do not silently enroll the last-served chat model just to make
startup validation pass. The existing service can be explicitly selected for
interactive smoke without changing pool membership.

## Remaining work / limits

- Full-duplex acoustic acceptance requires an attended session and explicit mic
  consent. No microphone capture permitted by this task. The callback crash fix
  is inherited; physical AEC/double-talk success is not established by mock tests.
- ASR is utterance-window HTTP, not fully incremental ASR. LLM/TTS stream.
- Native chat tools still lack video generation and audio/image interpretation;
  do not claim the historical video multimodal chat request is complete.
- Audio runtime still has one STT and one TTS lane. UI does not promise multiple
  concurrent models in one audio lane; chat/image/video residency follows actual
  runtime capacity. Recommendations do not mutate pool membership.
- Public release/main integration needs human review/authorization after local
  acceptance. No performance/latency improvement is claimed without measurement.
