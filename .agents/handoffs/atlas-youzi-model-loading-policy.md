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

## Local delivery completed (2026-09-07 20:18 CST)

- Source commit `8e3b51d8`, pushed to the task branch. Full native+sidecar builder
  ran on a clean source tree, with `BUNDLE_MODEL=0` (no bundled weight download),
  no `SKIP_SIDECAR`, and `RAPID_DESKTOP_NO_PORT_SWEEP=1`.
- Installed **0.14.4 (174), candidate-8e3b51d8** at the existing Applications path.
  Executable SHA-256:
  `1cb5c4137c7ec0fbea0cfb39b26bf515768236c7879feec4fa8d3aee68a81a91`.
- Old app backup: `~/Library/Application Support/Youzi/Client Backups/0.14.4-before-model-policy-20260907-201817/`.
  Both verified copied backup and original installed bundle retained. No runtime
  override modified: the existing 0.13.3 override is older than the 0.14.4 bundle.
- Strict deep codesign passed for candidate, backup, staged replacement and
  installed app. Required Sparkle executable-relative rpath is present.
- Isolated `/tmp` smoke used bundled Python `-P -B`, candidate-only PYTHONPATH,
  no user site packages: 10 package/route imports from the bundle, 5 text endpoint
  routing boundaries, exact-model rejection and authenticated live policy update
  passed. No weights loaded by this probe. Package `__init__.py` is intentionally
  retained; other exercised sidecar modules imported sourceless `.pyc`.
- Installed CLI version is 0.14.4. Offline `models --cached --json` parsed **41
  cache inventory entries**; this is inventory, not 41 loaded model services.
- Before replacement: existing chat service `/health` and `/health/ready` returned
  200; authenticated status reported zero running/waiting requests, all observed
  resident/audio lanes idle. Original app and supervised child quit normally.
- New client PID was 77546 at verification (never reuse without rechecking).
  Survived more than 3 minutes; no new Rapid crash reports after replacement.
  Confirmed launch environment disables port sweeping. Preferences still have an
  empty chat pool and disabled automatic startup; **no new inference service was
  started**, as intended. Do not describe this as an HTTP-ready inference server.

### Acceptance blocked by attended environment, not claimed as passed

The Mac reports `CGSSessionScreenIsLocked=1`. Native UI control has no visible
window; a separate accessibility query is denied. No unlock/permission bypass
was attempted. Post-install real GUI settings Save, explicit model startup and
real inference still require the user to unlock. Earlier rendered SwiftUI and
bundled mock-route passes are not substitutes for those interactions. Physical
full-duplex/AEC and native video-chat-tool gaps above remain open.

Next: after unlock, inspect model settings; have the user choose the desired
chat pool (or explicitly reuse the previously running chat model without changing
membership). Exercise Save against the running service and confirm default vs
exact Responses behavior. Perform attended voice acceptance only after explicit
microphone consent. Pixel owns visual acceptance; integration owns tool/API gaps.

## Follow-up: explicit video workspace selection

Read-only post-install inspection found two native gaps: capabilities requests
omitted the selected alias (therefore used the automatic pool), and readiness
required the selected video alias to own the chat process. Fixes remain scoped to
this task branch; no changes in the primary main worktree.

- Capability requests now encode the exact model query, including literal `+`.
- A selected video can be ready through canonical repository/alias residency while
  chat stays primary; loading/failed/evicting auxiliary entries remain unavailable.
- The UI observes a non-secret, stable identity (selection/readiness/session), not
  every metrics tick. Same-port/same-bearer session replacement invalidates old
  capability responses and gates submission until new controls are available.
- Cancellation still rejects stale results. No unsafe actor isolation changes,
  preference writes, loading, downloads or chat process replacement were added.
- Python policy/video/auth/residency targeted regression: **95 passed**. Native
  Release regression: **360 tests / 45 suites passed**, including video transport,
  workspace/co-load/session/cancellation, pool/settings/auth and live audio tests.
  Commands use the same environment flags and interpreter documented above; native
  filter additionally includes all `Video` suites. This is targeted regression,
  not a claim that the documented inherited full Python suite failure is resolved.
  Clean-commit full build/signature/bundled smoke and installation still follow.

The first new co-load test selected before history reconciliation; the existing
safety gate correctly refused that selection. The fixture now reconciles history
before selecting and still asserts exact on-demand requests, cold-state rejection
and unchanged automatic membership. No existing safety gate/assertion was removed.
